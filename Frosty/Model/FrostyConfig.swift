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

    enum Item: Equatable {
        case app(String)
        case group(Group)
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

    private enum CodingKeys: String, CodingKey { case items, autoHide, iconSize, icons, groupUnpinned }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        autoHide = try c.decodeIfPresent(Bool.self, forKey: .autoHide) ?? true
        iconSize = Self.clampIconSize(try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? 48)
        icons = try c.decodeIfPresent([String: String].self, forKey: .icons) ?? [:]
        groupUnpinned = try c.decodeIfPresent(Bool.self, forKey: .groupUnpinned) ?? true
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
    mutating func pin(_ id: String) {
        guard !placedBundleIDs.contains(id) else { return }
        items.append(.app(id))
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

    mutating func renameGroup(_ name: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, groupIndex(named: trimmed) == nil,
              let gi = groupIndex(named: name), case .group(var g) = items[gi] else { return }
        g.name = trimmed
        items[gi] = .group(g)
    }

    private func groupIndex(named name: String) -> Int? {
        items.firstIndex { if case .group(let g) = $0 { return g.name == name } else { return false } }
    }

    /// Removes every placement of `id`; returns the top-level index it was at.
    @discardableResult
    private mutating func remove(_ id: String) -> Int? {
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
