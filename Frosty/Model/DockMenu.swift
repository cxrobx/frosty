import CoreGraphics
import Foundation

/// An app's own Dock menu, copied out of the real Dock so Frosty can draw it
/// over its own tile. The Dock only ever opens the menu over its hidden icon,
/// and the menu can't be moved (its position reports settable = false, and a
/// write is accepted but ignored), so Frosty draws a copy instead.
struct DockMenuItem: Equatable, Codable {
    enum Kind: String, Equatable, Codable { case action, header, separator }

    var kind: Kind
    var title: String
    var checked = false
    /// Shown instead of the item before it while these modifiers are held
    /// (Hide Others under Hide, Force Quit under Quit).
    var alternate: Modifiers?
    var children: [DockMenuItem] = []

    struct Modifiers: OptionSet, Equatable, Codable {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let control = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }
}

/// One Dock menu item as Accessibility reports it.
struct RawDockMenuItem: Equatable {
    var title: String
    var enabled: Bool
    var markChar: String
    var frame: CGRect
    /// AXMenuItemCmdModifiers: Carbon bits, where 8 means *no* Command key.
    var cmdModifiers: Int
    /// A submenu's items, with the AXMenu that wraps them already skipped.
    var children: [RawDockMenuItem] = []
}

enum DockMenu {
    /// Titles of the items Frosty runs itself, with no trip through the Dock
    /// menu. English titles only: in another language every item goes through
    /// the Dock, which still works, with the brief flash.
    enum Local: Equatable { case hide, quit, forceQuit, showInFinder }

    static func local(_ path: [String]) -> Local? {
        switch path {
        case ["Hide"]: return .hide
        case ["Quit"]: return .quit
        case ["Force Quit"]: return .forceQuit
        case ["Options", "Show in Finder"]: return .showInFinder
        default: return nil
        }
    }

    static func items(from raw: [RawDockMenuItem], inOptions: Bool = false) -> [DockMenuItem] {
        var result: [DockMenuItem] = []
        var previous: RawDockMenuItem?
        for r in raw {
            defer { previous = r }
            // Keep in Dock pins the app to the hidden real Dock, not to Frosty.
            if inOptions && r.title == "Keep in Dock" { continue }
            if r.title.isEmpty {
                if !r.enabled { result.append(DockMenuItem(kind: .separator, title: "")) }
                continue
            }
            var item = DockMenuItem(kind: r.enabled ? .action : .header, title: r.title, checked: !r.markChar.isEmpty)
            // An alternate sits exactly where the item it replaces sits. A closed
            // submenu reports empty frames for everything, so those never match.
            if let p = previous, r.cmdModifiers != 0, r.frame == p.frame, r.frame.height > 0 {
                var mods = DockMenuItem.Modifiers(rawValue: r.cmdModifiers & 7)
                if r.cmdModifiers & 8 == 0 { mods.insert(.command) }
                item.alternate = mods
            }
            if !r.children.isEmpty {
                item.children = items(from: r.children, inOptions: r.title == "Options")
                item.kind = .action
            }
            result.append(item)
        }
        // A separator left at either end, or doubled, by a dropped item.
        var cleaned: [DockMenuItem] = []
        for item in result where !(item.kind == .separator && (cleaned.isEmpty || cleaned.last?.kind == .separator)) {
            cleaned.append(item)
        }
        if cleaned.last?.kind == .separator { cleaned.removeLast() }
        return cleaned
    }

    /// Where `path` (titles from the top) sits now, as child indices. Titles,
    /// not saved indices, because a recent-file list can shift between the copy
    /// and the pick; the first match wins.
    static func indexPath(of path: [String], in items: [RawDockMenuItem]) -> [Int]? {
        var level = items
        var result: [Int] = []
        for (depth, title) in path.enumerated() {
            guard let i = level.firstIndex(where: { $0.title == title }) else { return nil }
            result.append(i)
            if depth < path.count - 1 { level = level[i].children }
        }
        return result
    }
}

/// The copied menus, kept on disk so a restart of Frosty doesn't send every
/// app's first right-click back to the hidden Dock. An unreadable file is
/// treated as empty: the copies are rebuilt one right-click at a time.
struct DockMenuStore {
    let url: URL

    func load() -> [String: [DockMenuItem]] {
        guard let data = try? Data(contentsOf: url),
              let menus = try? JSONDecoder().decode([String: [DockMenuItem]].self, from: data) else { return [:] }
        return menus
    }

    func save(_ menus: [String: [DockMenuItem]]) {
        guard let data = try? JSONEncoder().encode(menus) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
