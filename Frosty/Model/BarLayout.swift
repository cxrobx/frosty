import Foundation

/// One slot on the bar, derived from the config plus what is running right now.
enum BarEntry: Equatable, Identifiable {
    case app(id: String, running: Bool, placed: Bool)
    case group(name: String, apps: [String], anyRunning: Bool)
    /// Stashed apps, then running apps that aren't placed anywhere, collected into one group.
    case openApps(apps: [String], anyRunning: Bool)
    case separator

    /// `openGroup` key for the Open Apps group. The control character keeps it
    /// from ever colliding with a group name typed into the rename prompt.
    static let openAppsKey = "\u{1}open-apps"
    static let openAppsTitle = "Open Apps"

    var id: String {
        switch self {
        case .app(let id, _, _): return "app:" + id
        case .group(let name, _, _): return "group:" + name
        case .openApps: return "open-apps"
        case .separator: return "separator"
        }
    }
}

enum BarLayout {
    /// Placed items first, in config order. Then, after a separator, the Open
    /// Apps group: stashed apps, running or not, and running apps that are not
    /// placed anywhere. Unplaced running apps join it only when `groupUnpinned`
    /// is on, and without a stash only when there are two or more (a group of
    /// one would only cost a click); otherwise they are shown loose. An app that
    /// lives in a group is never shown loose, even while it runs; the group
    /// lights up instead.
    static func entries(config: FrostyConfig, running: [String]) -> [BarEntry] {
        let runningSet = Set(running)
        var result: [BarEntry] = config.items.map { item in
            switch item {
            case .app(let id):
                return .app(id: id, running: runningSet.contains(id), placed: true)
            case .group(let g):
                return .group(name: g.name, apps: g.apps, anyRunning: g.apps.contains(where: runningSet.contains))
            }
        }
        var seen = config.placedBundleIDs
        let stashed = config.stash.filter { seen.insert($0).inserted }
        let loose = running.filter { seen.insert($0).inserted }
        let grouped = config.groupUnpinned && (!stashed.isEmpty || loose.count >= 2)
        var box = stashed
        if grouped { box += loose }
        if !box.isEmpty || !loose.isEmpty, !result.isEmpty { result.append(.separator) }
        if !box.isEmpty {
            result.append(.openApps(apps: box, anyRunning: box.contains(where: runningSet.contains)))
        }
        if !grouped {
            result += loose.map { .app(id: $0, running: true, placed: false) }
        }
        return result
    }
}

extension BarLayout {
    /// The display whose bottom edge the pointer is pressed against, as an index
    /// into `displays` (frames in AppKit's bottom-left coordinates). An edge with
    /// another display right below it is only a crossing, not the bottom.
    static func bottomEdgeDisplay(at p: CGPoint, displays: [CGRect]) -> Int? {
        displays.firstIndex { d in
            p.x >= d.minX && p.x < d.maxX && p.y >= d.minY - 1 && p.y <= d.minY + 1
                && !displays.contains { $0 != d && $0.contains(CGPoint(x: p.x, y: d.minY - 1)) }
        }
    }
}
