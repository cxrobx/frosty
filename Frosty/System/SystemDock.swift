import Foundation

/// The live `com.apple.dock` preferences, via the same CFPreferences calls the
/// `defaults` command uses.
struct SystemDockDefaults: DockDefaults {
    private let domain = "com.apple.dock" as CFString

    func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    func set(_ value: Any?, for key: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }

    func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Bundle ids of the apps pinned in the real Dock, used to seed Frosty on
    /// first launch. Finder is always first, as in the real Dock.
    func pinnedBundleIDs() -> [String] {
        let tiles = value("persistent-apps") as? [[String: Any]] ?? []
        let ids = tiles.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
        return ["com.apple.finder"] + ids.filter { $0 != "com.apple.finder" }
    }
}
