import AppKit
import Combine

/// Sits inside an app tile; see `FrostyModel.appTiles`.
final class AppTileMarker: NSView {
    var appID = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Where a dragged tile would land: beside a tile, or into a group.
struct DropHint: Equatable {
    enum Position { case before, after, into }
    let target: FrostyConfig.Ref
    let position: Position
}

/// The bar's state: the saved config plus the live list of running apps.
final class FrostyModel: ObservableObject {
    @Published private(set) var config: FrostyConfig {
        didSet { Apps.iconOverrides = config.icons }
    }
    @Published private(set) var running: [String] = []
    /// Badge text the real Dock shows, by bundle id. Empty unless badges are on
    /// and Frosty has Accessibility access.
    @Published private(set) var badges: [String: String] = [:]
    /// Bumped whenever an app's cached icon is dropped, so every icon redraws,
    /// including `GroupIcon`, which doesn't observe the model.
    @Published private(set) var iconEpoch = 0
    /// The tile being dragged, and where it would land if dropped now.
    var dragging: FrostyConfig.Ref?
    var dragToken: String?
    @Published var dropHint: DropHint? {
        didSet { if dropHint != nil { clearDropHintWhenReleased() } }
    }
    private var releaseWatch: Timer?
    /// The group whose app grid is open; keeps the bar from auto-hiding.
    @Published var openGroup: String?
    /// Horizontal centre of each group tile, in bar coordinates. Plain storage,
    /// not published, so reporting it never re-renders the bar.
    var groupTileMidX: [String: CGFloat] = [:]
    /// A view inside each app tile, measured when a right-click arrives, so the
    /// click can open the app's own Dock menu before SwiftUI opens Frosty's.
    let appTiles = NSHashTable<AppTileMarker>.weakObjects()

    /// The app tile under a point in a window's coordinates.
    func appTile(at point: NSPoint, in window: NSWindow) -> AppTileMarker? {
        appTiles.allObjects.first { $0.window === window && $0.convert($0.bounds, to: nil).contains(point) }
    }

    let configURL: URL
    private var observers: [NSObjectProtocol] = []
    private var badgeTimer: Timer?
    private let badgeQueue = DispatchQueue(label: "frosty.badges", qos: .utility)

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
        // Icons are cached for as long as Frosty runs, so an app whose icon changed on disk (an
        // update, a custom icon) would keep its old one. Read it again when the app launches, and
        // once more shortly after: an app can set its own icon just after it starts, as Onyx does.
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self?.reloadIcon(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reloadIcon(id) }
        })

        // The Dock tells nobody when a badge changes, so ask it every couple of seconds.
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshBadges() }
        badgeTimer?.tolerance = 0.5
        refreshBadges()
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        badgeTimer?.invalidate()
    }

    private func refreshBadges() {
        guard config.showBadges else {
            if !badges.isEmpty { badges = [:] }
            return
        }
        badgeQueue.async { [weak self] in
            let latest = RealDock.badges()
            DispatchQueue.main.async {
                guard let self, self.config.showBadges, latest != self.badges else { return }
                self.badges = latest
            }
        }
    }

    /// SwiftUI doesn't always report that a drag left a tile (seen on macOS 26
    /// when a drag ended off every target), which left the drop marker stuck.
    /// So the marker also goes as soon as no mouse button is held. The timer
    /// runs in the common modes, so it also ticks inside the drag's own loop.
    private func clearDropHintWhenReleased() {
        guard releaseWatch == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            timer.invalidate()
            self?.releaseWatch = nil
            self?.dropHint = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    /// The badge to draw on an app's tile, honouring both badge settings.
    func badge(_ id: String) -> String? {
        guard config.showBadges, !config.hiddenBadges.contains(id) else { return nil }
        return badges[id]
    }

    func groupBadge(_ apps: [String]) -> String? { Badge.combined(apps.compactMap(badge)) }

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

    private func reloadIcon(_ id: String) {
        Apps.forgetIcon(id)
        iconEpoch &+= 1
    }

    // MARK: - Edits (each one saves)

    func edit(_ change: (inout FrostyConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        save()
        // A drag or an edit can empty a group whose grid is open.
        if let open = openGroup, open != BarEntry.openAppsKey, !config.groupNames.contains(open) {
            openGroup = nil
        }
        refreshBadges()
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
