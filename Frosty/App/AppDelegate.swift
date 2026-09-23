import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Frosty", isDirectory: true)

    private let dock = SystemDockDefaults()
    private lazy var hider = DockHider(defaults: dock,
                                       snapshotURL: supportDir.appendingPathComponent("dock-original.json"))
    private var model: FrostyModel!
    private var bar: BarController!
    private var statusItem: NSStatusItem!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = FrostyModel(configURL: supportDir.appendingPathComponent("config.json"),
                            seed: dock.pinnedBundleIDs)
        bar = BarController(model: model)
        setUpStatusItem()
        restoreDockOnSignals()
        hideRealDock()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hider.restore()
    }

    // MARK: - Real Dock

    private func hideRealDock() {
        do {
            try hider.hide()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Frosty couldn't hide the Dock"
            alert.informativeText = "It could not save the Dock's current settings, so it left them alone.\n\n\(error)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// `kill` and Ctrl-C skip applicationWillTerminate, so route them through a
    /// normal quit, which restores the Dock. A hard crash still skips it; the
    /// saved originals then wait for the next launch or the status-menu item.
    private func restoreDockOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Frosty")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hideDock = NSMenuItem(title: "Hide the Real Dock", action: #selector(toggleRealDock), keyEquivalent: "")
        hideDock.state = hider.isHidden ? .on : .off
        let autoHide = NSMenuItem(title: "Auto-hide Frosty", action: #selector(toggleAutoHide), keyEquivalent: "")
        autoHide.state = model.config.autoHide ? .on : .off

        for item in [hideDock, autoHide,
                     .separator(),
                     NSMenuItem(title: "Edit Config…", action: #selector(editConfig), keyEquivalent: ""),
                     NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: ""),
                     .separator(),
                     NSMenuItem(title: "Quit Frosty (restores the Dock)", action: #selector(quit), keyEquivalent: "q")] {
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func toggleRealDock() {
        if hider.isHidden { hider.restore() } else { hideRealDock() }
    }

    @objc private func toggleAutoHide() {
        model.edit { $0.autoHide.toggle() }
        bar.layout(animated: true)
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open([model.configURL],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func reloadConfig() { model.reload() }

    @objc private func quit() { NSApp.terminate(nil) }
}
