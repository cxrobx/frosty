import AppKit
import Combine

/// The bar's state: the saved config plus the live list of running apps.
final class FrostyModel: ObservableObject {
    @Published private(set) var config: FrostyConfig {
        didSet { Apps.iconOverrides = config.icons }
    }
    @Published private(set) var running: [String] = []
    /// The group whose app grid is open; keeps the bar from auto-hiding.
    @Published var openGroup: String?
    /// Horizontal centre of each group tile, in bar coordinates. Plain storage,
    /// not published, so reporting it never re-renders the bar.
    var groupTileMidX: [String: CGFloat] = [:]

    let configURL: URL
    private var observers: [NSObjectProtocol] = []

    var entries: [BarEntry] { BarLayout.entries(config: config, running: running) }

    init(configURL: URL, seed: () -> [String]) {
        self.configURL = configURL
        if let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode(FrostyConfig.self, from: data) {
            config = saved
        } else {
            config = FrostyConfig(items: seed().map { .app($0) })
        }
        Apps.iconOverrides = config.icons
        save()
        refreshRunning()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshRunning()
            })
        }
    }

    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    private func refreshRunning() {
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        if ids != running { running = ids }
        // Close the Open Apps panel once there is no longer a group to show.
        if openGroup == BarEntry.openAppsKey,
           !entries.contains(where: { if case .openApps = $0 { return true } else { return false } }) {
            openGroup = nil
        }
    }

    func isRunning(_ id: String) -> Bool { running.contains(id) }

    // MARK: - Edits (each one saves)

    func edit(_ change: (inout FrostyConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        save()
    }

    /// Live resizing: called on every drag or slider tick. `persist` writes the
    /// config, so a drag saves once at the end instead of on every frame.
    func setIconSize(_ size: Double, persist: Bool) {
        let clamped = FrostyConfig.clampIconSize(size)
        if clamped != config.iconSize { config.iconSize = clamped }
        if persist { save() }
    }

    func reload() {
        guard let data = try? Data(contentsOf: configURL) else { return }
        do {
            config = try JSONDecoder().decode(FrostyConfig.self, from: data)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Frosty couldn't read its config"
            alert.informativeText = "\(configURL.path)\n\n\(error)\n\nThe bar is unchanged."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(config).write(to: configURL, options: .atomic)
    }
}
