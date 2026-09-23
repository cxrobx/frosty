import Foundation

/// One slot on the bar, derived from the config plus what is running right now.
enum BarEntry: Equatable, Identifiable {
    case app(id: String, running: Bool, placed: Bool)
    case group(name: String, apps: [String], anyRunning: Bool)
    /// Running apps that aren't placed anywhere, collected into one group.
    case openApps(apps: [String])
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
    /// Placed items first, in config order. Then, after a separator, running apps
    /// that are not placed anywhere: collected into one Open Apps group when
    /// `groupUnpinned` is on and there are two or more (a group of one would only
    /// cost a click), otherwise shown loose. An app that lives in a group is
    /// never shown loose, even while it runs; the group lights up instead.
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
        let placed = config.placedBundleIDs
        var seen = Set<String>()
        let loose = running.filter { !placed.contains($0) && seen.insert($0).inserted }
        if !loose.isEmpty {
            if !result.isEmpty { result.append(.separator) }
            if config.groupUnpinned && loose.count >= 2 {
                result.append(.openApps(apps: loose))
            } else {
                result += loose.map { .app(id: $0, running: true, placed: false) }
            }
        }
        return result
    }
}
