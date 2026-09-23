import AppKit
import ApplicationServices

/// The live, hidden, real Dock, reached through Accessibility: it still knows
/// things no public API tells anyone else, namely each app's own Dock menu and
/// its badge.
enum RealDock {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Raises the system's Accessibility prompt (or does nothing if granted).
    static func requestAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Shows the app's own Dock menu (New Message, recent documents, Options…).
    /// Returns false, leaving the caller to show Frosty's menu instead, if
    /// Frosty lacks Accessibility access or the app has no Dock icon.
    ///
    /// The Dock shows the menu over its own hidden icon, so it opens near the
    /// bottom centre rather than over Frosty's tile, and neither can be moved.
    /// Reading the items into Frosty's menu instead was tried and dropped: the
    /// Dock draws the menu before it can be read and closed, so it blinked on
    /// screen for about 130 ms on every right-click.
    @discardableResult
    static func showMenu(_ id: String) -> Bool {
        guard isTrusted else { return false }
        let items = appItems()
        let path = (Apps.url(id) ?? Apps.running(id)?.bundleURL)?.resolvingSymlinksInPath().path
        let name = Apps.name(id)
        // Matched on the app's location, falling back to its name for items that report no URL.
        guard let item = items.first(where: { path != nil && $0.url?.resolvingSymlinksInPath().path == path })
                ?? items.first(where: { $0.title == name }) else { return false }
        guard AXUIElementPerformAction(item.element, kAXShowMenuAction as CFString) == .success else { return false }
        menuOwner = item.element
        return true
    }

    /// The Dock icon whose menu `showMenu` last opened.
    private static var menuOwner: AXUIElement?

    /// Whether the menu `showMenu` opened is still up: the Dock hangs it under
    /// its icon while it shows. Frosty keeps the bar up until then.
    static var menuIsOpen: Bool {
        guard let owner = menuOwner else { return false }
        if children(owner).contains(where: { attribute($0, kAXRoleAttribute) as? String == "AXMenu" }) { return true }
        menuOwner = nil
        return false
    }

    /// Badge text by bundle id, for every app in the Dock that has one. Blocks
    /// on the Dock for a few milliseconds, so call it off the main thread.
    static func badges() -> [String: String] {
        guard isTrusted else { return [:] }
        var result: [String: String] = [:]
        for item in appItems() {
            guard let label = attribute(item.element, "AXStatusLabel") as? String, !label.isEmpty,
                  let url = item.url, let id = bundleID(url) else { continue }
            result[id] = label
        }
        return result
    }

    // MARK: - Accessibility plumbing

    private struct Item {
        let element: AXUIElement
        let title: String?
        let url: URL?
    }

    private static func appItems() -> [Item] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }
        let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
        // A hung Dock must not hang Frosty with it.
        AXUIElementSetMessagingTimeout(dockAX, 0.5)
        guard let list = children(dockAX).first(where: { attribute($0, kAXRoleAttribute) as? String == "AXList" })
        else { return [] }
        return children(list)
            .filter { attribute($0, kAXSubroleAttribute) as? String == "AXApplicationDockItem" }
            .map { Item(element: $0, title: attribute($0, kAXTitleAttribute) as? String,
                        url: attribute($0, kAXURLAttribute) as? URL) }
    }

    private static var bundleIDs: [URL: String] = [:]
    private static let bundleIDLock = NSLock()

    private static func bundleID(_ url: URL) -> String? {
        bundleIDLock.lock()
        defer { bundleIDLock.unlock() }
        if let cached = bundleIDs[url] { return cached }
        let id = Bundle(url: url)?.bundleIdentifier
        bundleIDs[url] = id
        return id
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
