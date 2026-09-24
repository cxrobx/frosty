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
    /// Forces the bar up regardless of the pointer (the status menu is open).
    var holdOpen = false {
        didSet { if holdOpen { setShown(true) } else { mouseMoved() } }
    }
    /// Frosty's own menus being tracked (a submenu counts separately).
    private var menusOpen = 0
    /// An app's own Dock menu, opened by a right-click on its tile, is up.
    private var dockMenuOpen = false
    private var dockMenuTimer: Timer?
    /// Each app's Dock menu, copied the first time the Dock shows it, so from
    /// then on Frosty draws it over its own tile. Refreshed on every pick that
    /// goes through the Dock.
    private var dockMenus: [String: [DockMenuItem]] = [:]
    private var hideWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    private let gap: CGFloat = 6          // space between the bar and the screen edge
    private let cornerRadius: CGFloat = 18

    init(model: FrostyModel) {
        self.model = model
        hosting = FirstMouseHostingView(rootView: BarView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]

        Self.frost(background, radius: cornerRadius)
        background.addSubview(hosting)
        panel.contentView = background

        // Refit the bar and the open group after any model change: tiles, badges
        // or icon size. The
        // hosting view never calls `invalidateIntrinsicContentSize` for a
        // content change, so waiting on it left the window at its old size
        // through a resize. `receive(on:)` runs after the change has landed.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                // Only a real size change: a relayout mid-slide would cut the animation short.
                if self.hosting.fittingSize != self.hosting.frame.size { self.layout(animated: false) }
                // After the bar, since the group sits above the tile it opened from.
                if let name = self.model.openGroup { self.placeGroupPanel(name) }
            }
            .store(in: &cancellables)
        model.$openGroup
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in self?.showGroup(name) }
            .store(in: &cancellables)
        // "Keep Frosty Open" can be switched from any tile's menu, not only the status menu.
        model.$config
            .map(\.autoHide)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.layout(animated: true)
                self?.mouseMoved()
            }
            .store(in: &cancellables)
        // A tile's right-click menu hangs outside the bar; keep the bar up while it is open.
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menusOpen += 1; self?.setShown(true) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.menusOpen = max(0, self.menusOpen - 1)
                self.mouseMoved()
            }
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
        // A right-click (or Control-click) on a running app opens the app's own
        // Dock menu, as in the real Dock. Holding Option gets Frosty's menu, and so
        // does any tile the Dock has no menu for; the event then goes on to SwiftUI.
        if let context = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown], handler: { [weak self] e in
            guard let self else { return e }
            return self.openDockMenu(for: e) ? nil : e
        }) {
            monitors.append(context)
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
        guard let name, shown, screen != nil else {
            groupPanel.orderOut(nil)
            groupHosting = nil
            return
        }
        let grid = FirstMouseHostingView(rootView: GroupGrid(model: model, name: name))
        grid.sizingOptions = [.intrinsicContentSize]
        let effect = NSVisualEffectView()
        Self.frost(effect, radius: 14)
        effect.addSubview(grid)
        groupPanel.contentView = effect
        groupHosting = grid
        placeGroupPanel(name)
        groupPanel.orderFrontRegardless()
    }

    private func placeGroupPanel(_ name: String) {
        guard let grid = groupHosting, model.openGroup == name, let screen else { return }
        let size = grid.fittingSize
        grid.frame = NSRect(origin: .zero, size: size)
        let tileX = panel.frame.minX + (model.groupTileMidX[name] ?? panel.frame.width / 2)
        let x = min(max(tileX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        groupPanel.setFrame(NSRect(x: x.rounded(), y: panel.frame.maxY + 8, width: size.width, height: size.height),
                            display: true)
    }

    private func openDockMenu(for event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let contextClick = event.type == .rightMouseDown || flags.contains(.control)
        guard contextClick, !flags.contains(.option), let window = event.window,
              let tile = model.appTile(at: event.locationInWindow, in: window),
              model.isRunning(tile.appID) else { return false }
        let id = tile.appID
        if let items = dockMenus[id] {
            // Out of the event monitor first: the menu runs its own tracking loop.
            DispatchQueue.main.async { self.popUpDockMenu(items, for: id, over: tile) }
            return true
        }
        guard RealDock.showMenu(id) else { return false }
        watchDockMenu(id)
        return true
    }

    /// The Dock's menu gives no sign when it closes, so look every 50 ms
    /// while it is up; `keepsBarOpen` holds the bar until then. The first look
    /// that finds it also copies it for next time, early enough that a menu
    /// closed at once is still copied.
    private func watchDockMenu(_ id: String) {
        dockMenuTimer?.invalidate()
        dockMenuOpen = true
        dockMenuTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { return }
            if self.dockMenus[id] == nil, let raw = RealDock.openMenuItems() {
                self.dockMenus[id] = DockMenu.items(from: raw)
            }
            guard !RealDock.menuIsOpen else { return }
            timer.invalidate()
            self.dockMenuOpen = false
            self.mouseMoved()
        }
    }

    /// The copied Dock menu, centred above the tile like the real one.
    private func popUpDockMenu(_ items: [DockMenuItem], for id: String, over tile: NSView) {
        guard let view = panel.contentView else { return }
        let target = DockMenuTarget { [weak self] path in self?.perform(path, for: id) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        Self.fill(menu, with: items, path: [], target: target)
        // `NSMenu.size` counts hidden alternates (Hide Others, Force Quit) as
        // rows, which floated the menu a row per alternate above the bar, so
        // measure a copy without them.
        let measure = NSMenu()
        Self.fill(measure, with: items.filter { $0.alternate == nil }, path: [], target: target)
        let tileRect = tile.convert(tile.bounds, to: view)
        let point = NSPoint(x: tileRect.midX - menu.size.width / 2, y: view.bounds.maxY + 6 + measure.size.height)
        withExtendedLifetime(target) { _ = menu.popUp(positioning: nil, at: point, in: view) }
    }

    private static func fill(_ menu: NSMenu, with items: [DockMenuItem], path: [String], target: DockMenuTarget) {
        for item in items {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                let header = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            case .action:
                let entry = NSMenuItem(title: item.title, action: #selector(DockMenuTarget.choose(_:)), keyEquivalent: "")
                entry.target = target
                entry.representedObject = path + [item.title]
                entry.state = item.checked ? .on : .off
                entry.keyEquivalentModifierMask = []
                if let alternate = item.alternate {
                    entry.isAlternate = true
                    var mask: NSEvent.ModifierFlags = []
                    if alternate.contains(.shift) { mask.insert(.shift) }
                    if alternate.contains(.option) { mask.insert(.option) }
                    if alternate.contains(.control) { mask.insert(.control) }
                    if alternate.contains(.command) { mask.insert(.command) }
                    entry.keyEquivalentModifierMask = mask
                }
                if !item.children.isEmpty {
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    fill(submenu, with: item.children, path: path + [item.title], target: target)
                    entry.action = nil
                    entry.submenu = submenu
                }
                menu.addItem(entry)
            }
        }
    }

    /// Runs a picked item: the common ones directly, the rest through the Dock
    /// menu itself, which flashes up for a moment at the bottom of the screen.
    private func perform(_ path: [String], for id: String) {
        switch DockMenu.local(path) {
        case .hide: Apps.hide(id)
        case .quit: Apps.quit(id)
        case .forceQuit: Apps.running(id)?.forceTerminate()
        case .showInFinder: Apps.revealInFinder(id)
        case nil:
            DispatchQueue.global(qos: .userInitiated).async {
                let result = RealDock.pick(id, path: path)
                DispatchQueue.main.async { [weak self] in
                    if let raw = result.items { self?.dockMenus[id] = DockMenu.items(from: raw) }
                    if !result.picked { NSSound.beep() }
                }
            }
        }
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

    /// The pointer is over the bar (with some slack), or over an open group
    /// popover, or a button is held: a drag of a tile must not lose its target.
    private func keepsBarOpen(_ p: NSPoint) -> Bool {
        // Menus, Frosty's or the app's own Dock menu, hang outside the bar.
        if holdOpen || menusOpen > 0 || dockMenuOpen || NSEvent.pressedMouseButtons != 0 { return true }
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

/// Receives picks from a copied Dock menu.
private final class DockMenuTarget: NSObject {
    private let handler: ([String]) -> Void
    init(_ handler: @escaping ([String]) -> Void) { self.handler = handler }

    @objc func choose(_ item: NSMenuItem) {
        if let path = item.representedObject as? [String] { handler(path) }
    }
}
