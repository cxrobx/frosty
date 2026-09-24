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

    /// Shows the app's own Dock menu (New Message, recent documents, Options…)
    /// where the Dock puts it: over its own hidden icon, near the bottom centre.
    /// Frosty does this only until it has a copy of the menu to draw at its own
    /// tile (see `DockMenu`). Returns false, leaving the caller to show Frosty's
    /// menu instead, if Frosty lacks Accessibility access or the app has no Dock icon.
    @discardableResult
    static func showMenu(_ id: String) -> Bool {
        guard let item = openMenu(id) else { return false }
        menuOwner = item
        return true
    }

    /// The menu `showMenu` opened, read while it is up, so Frosty can draw it
    /// itself next time. Nil once it has closed.
    static func openMenuItems() -> [RawDockMenuItem]? {
        guard let owner = menuOwner, let menu = menu(of: owner) else { return nil }
        return nodes(menu).map(\.raw)
    }

    /// Picks `path` (titles from the top) in the app's Dock menu: opens the
    /// menu, which shows for a moment, and presses the item. Returns what the
    /// menu held, for Frosty's copy, and whether the item was still there. A
    /// closed submenu's items can be pressed directly. Blocks for up to a
    /// second, so call it off the main thread.
    static func pick(_ id: String, path: [String]) -> (picked: Bool, items: [RawDockMenuItem]?) {
        guard let item = openMenu(id) else { return (false, nil) }
        var menu: AXUIElement?
        for _ in 0..<100 {
            menu = self.menu(of: item)
            if menu != nil { break }
            usleep(10_000)
        }
        guard let menu else { return (false, nil) }
        let tree = nodes(menu)
        let items = tree.map(\.raw)
        guard let indices = DockMenu.indexPath(of: path, in: items) else {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            return (false, items)
        }
        var level = tree
        var target = tree[indices[0]]
        for i in indices.dropFirst() {
            level = target.children
            target = level[i]
        }
        return (AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success, items)
    }

    /// Asks the Dock to open the app's menu over its hidden icon.
    private static func openMenu(_ id: String) -> AXUIElement? {
        guard isTrusted else { return nil }
        let items = appItems()
        let path = (Apps.url(id) ?? Apps.running(id)?.bundleURL)?.resolvingSymlinksInPath().path
        let name = Apps.name(id)
        // Matched on the app's location, falling back to its name for items that report no URL.
        guard let item = items.first(where: { path != nil && $0.url?.resolvingSymlinksInPath().path == path })
                ?? items.first(where: { $0.title == name }),
              AXUIElementPerformAction(item.element, kAXShowMenuAction as CFString) == .success else { return nil }
        return item.element
    }

    /// The Dock icon whose menu `showMenu` last opened.
    private static var menuOwner: AXUIElement?

    /// Whether the menu `showMenu` opened is still up: the Dock hangs it under
    /// its icon while it shows. Frosty keeps the bar up until then.
    static var menuIsOpen: Bool {
        guard let owner = menuOwner else { return false }
        if menu(of: owner) != nil { return true }
        menuOwner = nil
        return false
    }

    private static func menu(of item: AXUIElement) -> AXUIElement? {
        children(item).first { attribute($0, kAXRoleAttribute) as? String == "AXMenu" }
    }

    private struct Node {
        let element: AXUIElement
        let raw: RawDockMenuItem
        let children: [Node]
    }

    /// A menu's items, each submenu read through the AXMenu that wraps it.
    private static func nodes(_ menu: AXUIElement) -> [Node] {
        children(menu).map { element in
            let kids = self.menu(of: element).map(nodes) ?? []
            var frame = CGRect.zero
            if let value = attribute(element, "AXFrame") { AXValueGetValue(value as! AXValue, .cgRect, &frame) }
            let raw = RawDockMenuItem(
                title: attribute(element, kAXTitleAttribute) as? String ?? "",
                enabled: attribute(element, kAXEnabledAttribute) as? Bool ?? false,
                markChar: attribute(element, kAXMenuItemMarkCharAttribute) as? String ?? "",
                frame: frame,
                cmdModifiers: attribute(element, kAXMenuItemCmdModifiersAttribute) as? Int ?? 0,
                children: kids.map(\.raw))
            return Node(element: element, raw: raw, children: kids)
        }
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
