import Foundation

/// What the user has placed on the bar. Stored as hand-editable JSON:
///
///     { "autoHide": true, "iconSize": 48,
///       "items": [ { "app": "com.apple.finder" },
///                  { "group": "Music", "apps": ["com.image-line.flstudio", "com.cockos.reaper"] } ],
///       "icons": { "md.obsidian": "~/Library/Application Support/obsidian/icon.png" } }
///
/// `icons` overrides an app's icon with an image file. It exists because an app
/// that swaps its Dock icon at runtime (Obsidian's App icon setting) only tells
/// the Dock; every public API still returns the icon inside the .app.
struct FrostyConfig: Codable, Equatable {
    var items: [Item]
    var autoHide: Bool = true
    var iconSize: Double = 48
    var icons: [String: String] = [:]
    /// Collect running apps that aren't placed into one Open Apps group.
    var groupUnpinned: Bool = true
    /// Show the badges apps put on their Dock icons (unread counts and the like).
    var showBadges: Bool = true
    /// Apps whose badge is hidden even while badges are on.
    var hiddenBadges: Set<String> = []
    /// Copy each app's Dock menu fresh on every right-click, hiding the real
    /// menu's flash under a still of the screen. Needs Screen Recording.
    var freshDockMenus: Bool = false
    /// The display the bar was last moved to, by its UUID (a display's id can
    /// change across a replug or a restart). Absent means the main display.
    var display: String?
    /// Apps kept in the Open Apps group even when they are not running.
    var stash: [String] = []

    enum Item: Equatable {
        case app(String)
        case group(Group)
    }

    /// A tile on the bar, as named by a drag: an app (placed or not) or a group.
    enum Ref: Equatable {
        case app(String)
        case group(String)
    }

    struct Group: Equatable {
        var name: String
        var apps: [String]
    }

    init(items: [Item], autoHide: Bool = true, iconSize: Double = 48, icons: [String: String] = [:]) {
        self.items = items
        self.autoHide = autoHide
        self.iconSize = iconSize
        self.icons = icons
    }

    private enum CodingKeys: String, CodingKey { case items, autoHide, iconSize, icons, groupUnpinned, showBadges, hiddenBadges, freshDockMenus, display, stash }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        autoHide = try c.decodeIfPresent(Bool.self, forKey: .autoHide) ?? true
        iconSize = Self.clampIconSize(try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? 48)
        icons = try c.decodeIfPresent([String: String].self, forKey: .icons) ?? [:]
        groupUnpinned = try c.decodeIfPresent(Bool.self, forKey: .groupUnpinned) ?? true
        showBadges = try c.decodeIfPresent(Bool.self, forKey: .showBadges) ?? true
        hiddenBadges = Set(try c.decodeIfPresent([String].self, forKey: .hiddenBadges) ?? [])
        freshDockMenus = try c.decodeIfPresent(Bool.self, forKey: .freshDockMenus) ?? false
        display = try c.decodeIfPresent(String.self, forKey: .display)
        stash = try c.decodeIfPresent([String].self, forKey: .stash) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encode(autoHide, forKey: .autoHide)
        try c.encode(iconSize, forKey: .iconSize)
        try c.encode(icons, forKey: .icons)
        try c.encode(groupUnpinned, forKey: .groupUnpinned)
        try c.encode(showBadges, forKey: .showBadges)
        // Sorted, so the file doesn't churn between saves.
        try c.encode(hiddenBadges.sorted(), forKey: .hiddenBadges)
        try c.encode(freshDockMenus, forKey: .freshDockMenus)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encode(stash, forKey: .stash)
    }

    /// Same range as the real Dock's size slider.
    static let iconSizeRange: ClosedRange<Double> = 16...128

    static func clampIconSize(_ size: Double) -> Double {
        min(max(size.rounded(), iconSizeRange.lowerBound), iconSizeRange.upperBound)
    }

    /// Every bundle id the user has placed, top level or inside a group.
    var placedBundleIDs: Set<String> {
        var ids = Set<String>()
        for item in items {
            switch item {
            case .app(let id): ids.insert(id)
            case .group(let g): ids.formUnion(g.apps)
            }
        }
        return ids
    }

    var groupNames: [String] {
        items.compactMap { if case .group(let g) = $0 { return g.name } else { return nil } }
    }
}

extension FrostyConfig.Item: Codable {
    private enum Keys: String, CodingKey { case app, group, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .app) {
            self = .app(id)
        } else if let name = try c.decodeIfPresent(String.self, forKey: .group) {
            self = .group(.init(name: name, apps: try c.decodeIfPresent([String].self, forKey: .apps) ?? []))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .app, in: c,
                debugDescription: "item needs an \"app\" or a \"group\" key")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .app(let id):
            try c.encode(id, forKey: .app)
        case .group(let g):
            try c.encode(g.name, forKey: .group)
            try c.encode(g.apps, forKey: .apps)
        }
    }
}

// MARK: - Edits

extension FrostyConfig {
    /// Add an app to the end of the bar, unless it is already placed somewhere.
    /// A stashed app leaves the stash for it.
    mutating func pin(_ id: String) {
        guard !placedBundleIDs.contains(id) else { return }
        stash.removeAll { $0 == id }
        items.append(.app(id))
    }

    /// Keep an app in the Open Apps group, running or not, taking it off the bar.
    mutating func stash(_ id: String) {
        remove(id)
        stash.append(id)
    }

    /// Take an app off the bar entirely. A group left empty goes with it.
    mutating func unpin(_ id: String) {
        _ = remove(id)
    }

    /// Move an app into a group, creating the group where the app sat if needed.
    mutating func move(_ id: String, toGroup name: String) {
        let position = remove(id) ?? items.count
        if let gi = groupIndex(named: name), case .group(var g) = items[gi] {
            g.apps.append(id)
            items[gi] = .group(g)
        } else {
            items.insert(.group(.init(name: name, apps: [id])), at: min(position, items.count))
        }
    }

    /// Pull an app out of its group and pin it right after that group.
    mutating func removeFromGroup(_ id: String) {
        guard let gi = items.firstIndex(where: {
            if case .group(let g) = $0 { return g.apps.contains(id) } else { return false }
        }), case .group(var g) = items[gi] else { return }
        g.apps.removeAll { $0 == id }
        if g.apps.isEmpty {
            items[gi] = .app(id)
        } else {
            items[gi] = .group(g)
            items.insert(.app(id), at: gi + 1)
        }
    }

    /// Dissolve a group, leaving its apps in its place.
    mutating func ungroup(_ name: String) {
        guard let gi = groupIndex(named: name), case .group(let g) = items[gi] else { return }
        items.replaceSubrange(gi...gi, with: g.apps.map { .app($0) })
    }

    /// Drop a dragged tile next to another one. An app dropped beside an app
    /// inside a group joins that group there; anything else lands on the top
    /// level, which also pins an app that wasn't placed. Groups never nest, and
    /// a target that isn't placed (a loose running app) leaves everything as is.
    mutating func place(_ dragged: Ref, beside target: Ref, after: Bool) {
        guard dragged != target else { return }
        let saved = items
        switch dragged {
        case .group(let name):
            guard let gi = groupIndex(named: name) else { return }
            let group = items.remove(at: gi)
            guard let ti = topLevelIndex(of: target) else { items = saved; return }
            items.insert(group, at: after ? ti + 1 : ti)
        case .app(let id):
            if case .app(let targetID) = target, let name = groupName(containing: targetID) {
                remove(id)
                // The target is still in the group, so the group survived the removal.
                guard let gi = groupIndex(named: name), case .group(var g) = items[gi],
                      let ai = g.apps.firstIndex(of: targetID) else { items = saved; return }
                g.apps.insert(id, at: after ? ai + 1 : ai)
                items[gi] = .group(g)
            } else {
                remove(id)
                guard let ti = topLevelIndex(of: target) else { items = saved; return }
                items.insert(.app(id), at: after ? ti + 1 : ti)
            }
        }
    }

    mutating func toggleBadge(_ id: String) {
        if hiddenBadges.remove(id) == nil { hiddenBadges.insert(id) }
    }

    mutating func renameGroup(_ name: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, groupIndex(named: trimmed) == nil,
              let gi = groupIndex(named: name), case .group(var g) = items[gi] else { return }
        g.name = trimmed
        items[gi] = .group(g)
    }

    private func topLevelIndex(of ref: Ref) -> Int? {
        switch ref {
        case .app(let id): return items.firstIndex(of: .app(id))
        case .group(let name): return groupIndex(named: name)
        }
    }

    private func groupName(containing id: String) -> String? {
        for case .group(let g) in items where g.apps.contains(id) { return g.name }
        return nil
    }

    private func groupIndex(named name: String) -> Int? {
        items.firstIndex { if case .group(let g) = $0 { return g.name == name } else { return false } }
    }

    /// Removes every placement of `id`, the stash included; returns the
    /// top-level index it was at.
    @discardableResult
    private mutating func remove(_ id: String) -> Int? {
        stash.removeAll { $0 == id }
        var position: Int?
        var result: [Item] = []
        for item in items {
            switch item {
            case .app(let other):
                if other == id { position = position ?? result.count } else { result.append(item) }
            case .group(var g):
                if g.apps.contains(id) {
                    g.apps.removeAll { $0 == id }
                    position = position ?? result.count
                    if !g.apps.isEmpty { result.append(.group(g)) }
                } else {
                    result.append(item)
                }
            }
        }
        items = result
        return position
    }
}
