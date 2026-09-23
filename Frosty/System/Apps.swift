import AppKit

/// Looks up, launches and controls apps by bundle id.
enum Apps {
    private static var iconCache: [String: NSImage] = [:]
    /// Per-app icon files from the config (`~` allowed). Setting it clears the cache.
    static var iconOverrides: [String: String] = [:] {
        didSet { if iconOverrides != oldValue { iconCache.removeAll() } }
    }

    static func url(_ id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    static func running(_ id: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    static func name(_ id: String) -> String {
        if let url = url(id) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return running(id)?.localizedName ?? id
    }

    static func icon(_ id: String) -> NSImage {
        if let cached = iconCache[id] { return cached }
        let image: NSImage
        if let path = iconOverrides[id],
           let custom = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath) {
            image = custom
        } else if let url = url(id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let icon = running(id)?.icon {
            image = icon
        } else {
            image = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil)!
        }
        iconCache[id] = image
        return image
    }

    /// Launches the app, or brings it forward if it is running. Going through
    /// `openApplication` rather than `NSRunningApplication.activate` matters:
    /// it sends the reopen event, so an app with no windows opens one, exactly
    /// like a click in the real Dock, and it is not subject to macOS 14's
    /// cooperative-activation refusals for background apps.
    static func open(_ id: String) {
        guard let url = url(id) else {
            running(id)?.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    static func hide(_ id: String) { running(id)?.hide() }
    static func quit(_ id: String) { running(id)?.terminate() }

    static func revealInFinder(_ id: String) {
        if let url = url(id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
