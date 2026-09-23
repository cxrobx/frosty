import Foundation

/// Read/write access to the real Dock's preferences. Abstracted so the
/// save-and-restore logic can be tested without touching the live Dock.
protocol DockDefaults {
    func value(_ key: String) -> Any?
    func set(_ value: Any?, for key: String)   // nil deletes the key
    func restartDock()
}

/// The Dock settings Frosty changes, as they were before it changed them.
/// `nil` means the key was absent (macOS default), so restore deletes it.
struct DockSnapshot: Codable, Equatable {
    var autohide: Bool?
    var autohideDelay: Double?
}

/// Hides the real Dock by making it auto-hide with a reveal delay nobody will
/// ever wait out, and puts the original settings back afterwards.
///
/// The originals are written to disk *before* anything changes and are only
/// deleted after a restore. So if Frosty crashes while the Dock is hidden, the
/// next launch finds the file and keeps the true originals instead of saving the
/// hidden state as if it were the user's.
final class DockHider {
    static let hiddenDelay: Double = 1000

    private let defaults: DockDefaults
    private let snapshotURL: URL

    init(defaults: DockDefaults, snapshotURL: URL) {
        self.defaults = defaults
        self.snapshotURL = snapshotURL
    }

    var isHidden: Bool { FileManager.default.fileExists(atPath: snapshotURL.path) }

    func hide() throws {
        if !isHidden {
            let snapshot = DockSnapshot(
                autohide: (defaults.value("autohide") as? NSNumber)?.boolValue,
                autohideDelay: (defaults.value("autohide-delay") as? NSNumber)?.doubleValue)
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
        }
        defaults.set(true, for: "autohide")
        defaults.set(Self.hiddenDelay, for: "autohide-delay")
        defaults.restartDock()
    }

    func restore() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(DockSnapshot.self, from: data) else { return }
        defaults.set(snapshot.autohide, for: "autohide")
        // Never "restore" our own sentinel if it somehow got captured.
        let delay = snapshot.autohideDelay == Self.hiddenDelay ? nil : snapshot.autohideDelay
        defaults.set(delay, for: "autohide-delay")
        defaults.restartDock()
        try? FileManager.default.removeItem(at: snapshotURL)
    }
}
