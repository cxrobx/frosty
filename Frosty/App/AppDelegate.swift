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

    // Keep the bar up while the menu is open, so the size slider is visible live.
    func menuWillOpen(_ menu: NSMenu) { bar.holdOpen = true }
    func menuDidClose(_ menu: NSMenu) { bar.holdOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hideDock = NSMenuItem(title: "Hide the Real Dock", action: #selector(toggleRealDock), keyEquivalent: "")
        hideDock.state = hider.isHidden ? .on : .off
        let autoHide = NSMenuItem(title: "Auto-hide Frosty", action: #selector(toggleAutoHide), keyEquivalent: "")
        autoHide.state = model.config.autoHide ? .on : .off
        let groupUnpinned = NSMenuItem(title: "Group Unpinned Apps", action: #selector(toggleGroupUnpinned), keyEquivalent: "")
        groupUnpinned.state = model.config.groupUnpinned ? .on : .off

        let sizeItem = NSMenuItem()
        sizeItem.view = iconSizeSliderView()

        for item in [hideDock, autoHide, groupUnpinned,
                     .separator(),
                     sizeItem,
                     .separator(),
                     NSMenuItem(title: "Edit Config…", action: #selector(editConfig), keyEquivalent: ""),
                     NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: ""),
                     .separator(),
                     NSMenuItem(title: "Quit Frosty (restores the Dock)", action: #selector(quit), keyEquivalent: "q")] {
            item.target = self
            menu.addItem(item)
        }
    }

    private func iconSizeSliderView() -> NSView {
        let label = NSTextField(labelWithString: "Icon Size")
        label.font = .menuFont(ofSize: 0)
        let slider = NSSlider(value: model.config.iconSize,
                              minValue: FrostyConfig.iconSizeRange.lowerBound,
                              maxValue: FrostyConfig.iconSizeRange.upperBound,
                              target: self, action: #selector(iconSizeChanged))
        slider.isContinuous = true
        slider.controlSize = .small
        let stack = NSStackView(views: [label, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        stack.frame = NSRect(x: 0, y: 0, width: 220, height: 48)
        slider.widthAnchor.constraint(equalToConstant: 192).isActive = true
        return stack
    }

    @objc private func iconSizeChanged(_ slider: NSSlider) {
        let dragging = NSApp.currentEvent?.type == .leftMouseDragged
        model.setIconSize(slider.doubleValue, persist: !dragging)
    }

    @objc private func toggleRealDock() {
        if hider.isHidden { hider.restore() } else { hideRealDock() }
    }

    @objc private func toggleAutoHide() {
        model.edit { $0.autoHide.toggle() }
        bar.layout(animated: true)
    }

    @objc private func toggleGroupUnpinned() {
        model.edit { $0.groupUnpinned.toggle() }
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open([model.configURL],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func reloadConfig() { model.reload() }

    @objc private func quit() { NSApp.terminate(nil) }
}
