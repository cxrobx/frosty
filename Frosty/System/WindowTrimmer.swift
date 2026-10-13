import AppKit
import ApplicationServices

/// Keeps filled and tiled windows clear of the bar while it stays up.
///
/// The reserved strip (`ScreenReservation`) covers maximize, but macOS 26's
/// Fill, tiling and the green button's Option-click ignore it while the real
/// Dock auto-hides, and so do apps that maximize themselves, like Zen. All of
/// them leave the window's bottom edge exactly on the bottom of the screen,
/// so Frosty watches every app's windows through Accessibility and trims a
/// window that lands there to stop above the bar. A window dragged partly off
/// the bottom doesn't end exactly on the edge, so it is left alone.
final class WindowTrimmer {
    /// The strip to keep windows out of (window server coordinates), or nil
    /// while the bar auto-hides.
    private let strip: () -> CGRect?
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: [CFHashCode: (AXUIElement, DispatchWorkItem)] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Fill animates; check once it has settled.
    private static let settle: TimeInterval = 0.3
    private static let notifications = [kAXWindowResizedNotification, kAXWindowMovedNotification]

    init(strip: @escaping () -> CGRect?) {
        self.strip = strip
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.watch(app) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.unwatch(app) }
            },
        ]
        NSWorkspace.shared.runningApplications.forEach(watch)
    }

    /// Watching needs Accessibility; call again once it is granted.
    func watchRunningApps() {
        NSWorkspace.shared.runningApplications.forEach(watch)
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowTrimmer>.fromOpaque(refcon).takeUnretainedValue().windowChanged(element)
        }, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Trims every window already filled, for when the bar starts staying up.
    func trimAll() {
        guard AXIsProcessTrusted(), strip() != nil else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                                kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            windows.forEach(trim)
        }
    }

    private func unwatch(_ app: NSRunningApplication) {
        guard let observer = observers.removeValue(forKey: app.processIdentifier) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func windowChanged(_ window: AXUIElement) {
        guard strip() != nil else { return }
        let key = CFHash(window)
        pending[key]?.1.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending[key] = nil
            self?.trim(window)
        }
        pending[key] = (window, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func trim(_ window: AXUIElement) {
        guard let strip = strip(), !isFullScreen(window),
              let origin = point(window, kAXPositionAttribute), let size = size(window, kAXSizeAttribute),
              let height = ReservedStrip.trimmedHeight(windowTop: origin.y, windowHeight: size.height,
                                                       windowMinX: origin.x, windowMaxX: origin.x + size.width,
                                                       strip: strip) else { return }
        var newSize = CGSize(width: size.width, height: height)
        if let value = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success
            && (value as? Bool) == true
    }

    private func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: AnyObject?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: AnyObject?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
