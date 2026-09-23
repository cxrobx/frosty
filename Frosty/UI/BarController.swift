import AppKit
import Combine
import SwiftUI

/// A panel that never takes focus, so clicking the bar leaves the frontmost app
/// frontmost, exactly like the real Dock.
final class BarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true   // before `level`: setting this resets the level to .floating
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Let the bar sit below the bottom edge while hidden.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Clicks land on the first try even though the panel is never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Places the bar on the main display and slides it in and out.
final class BarController {
    private let model: FrostyModel
    private let panel = BarPanel()
    private let hosting: FirstMouseHostingView<BarView>
    private let background = NSVisualEffectView()
    /// The open group's app grid: a second never-key panel, so its tiles also
    /// take the first click (a SwiftUI popover swallowed it).
    private let groupPanel = BarPanel()
    private var groupHosting: FirstMouseHostingView<GroupGrid>?
    private var shown = false
    private var hideWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    private let gap: CGFloat = 6          // space between the bar and the screen edge
    private let cornerRadius: CGFloat = 18

    init(model: FrostyModel) {
        self.model = model
        hosting = FirstMouseHostingView(rootView: BarView(model: model))

        Self.frost(background, radius: cornerRadius)
        background.addSubview(hosting)
        panel.contentView = background

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.layout(animated: false) }
            .store(in: &cancellables)
        model.$openGroup
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in self?.showGroup(name) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout(animated: false) }
            .store(in: &cancellables)

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] e in self?.mouseMoved(); return e }) {
            monitors.append(local)
        }
        // A global monitor only sees clicks in other apps: any of them closes the group.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                          handler: { [weak self] _ in self?.model.openGroup = nil }) {
            monitors.append(clicks)
        }

        shown = !model.config.autoHide
        layout(animated: false)
        panel.orderFrontRegardless()
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    /// The display with the menu bar, where the real Dock lives by default.
    private var screen: NSScreen? { NSScreen.screens.first }

    private func frame(shown: Bool) -> NSRect {
        guard let screen else { return .zero }
        let size = hosting.fittingSize
        let x = (screen.frame.midX - size.width / 2).rounded()
        let y = shown ? screen.frame.minY + gap : screen.frame.minY - size.height - 20
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func layout(animated: Bool) {
        if !model.config.autoHide { shown = true }
        let target = frame(shown: shown)
        hosting.frame = NSRect(origin: .zero, size: target.size)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func showGroup(_ name: String?) {
        guard let name, shown, let screen else {
            groupPanel.orderOut(nil)
            groupHosting = nil
            return
        }
        let grid = FirstMouseHostingView(rootView: GroupGrid(model: model, name: name))
        let size = grid.fittingSize
        grid.frame = NSRect(origin: .zero, size: size)
        let effect = NSVisualEffectView()
        Self.frost(effect, radius: 14)
        effect.addSubview(grid)
        groupPanel.contentView = effect
        groupHosting = grid

        let tileX = panel.frame.minX + (model.groupTileMidX[name] ?? panel.frame.width / 2)
        let x = min(max(tileX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        groupPanel.setFrame(NSRect(x: x.rounded(), y: panel.frame.maxY + 8, width: size.width, height: size.height),
                            display: true)
        groupPanel.orderFrontRegardless()
    }

    private func setShown(_ value: Bool) {
        guard value != shown else { return }
        shown = value
        layout(animated: true)
    }

    private func mouseMoved() {
        guard model.config.autoHide, let screen else { return }
        let p = NSEvent.mouseLocation

        if !shown {
            let atBottomEdge = p.y <= screen.frame.minY + 1 && p.x >= screen.frame.minX && p.x <= screen.frame.maxX
            if atBottomEdge { setShown(true) }
            return
        }

        if keepsBarOpen(p) {
            hideWork?.cancel()
            hideWork = nil
        } else if hideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                guard !self.keepsBarOpen(NSEvent.mouseLocation) else { return }
                self.model.openGroup = nil
                self.setShown(false)
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// The pointer is over the bar (with some slack), or over an open group popover.
    private func keepsBarOpen(_ p: NSPoint) -> Bool {
        if panel.frame.insetBy(dx: -16, dy: -16).contains(p) { return true }
        // The gap between the bar and the group panel counts as inside.
        return groupPanel.isVisible && groupPanel.frame.union(panel.frame).insetBy(dx: -16, dy: -16).contains(p)
    }

    private static func frost(_ view: NSVisualEffectView, radius: CGFloat) {
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = roundedMask(radius: radius)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
