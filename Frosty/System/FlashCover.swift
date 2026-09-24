import AppKit
import ScreenCaptureKit

/// Hides the real Dock's menu while Frosty copies it, so every right-click can
/// take a fresh copy without the menu flashing at the bottom of the screen.
///
/// Before the Dock opens its menu, the strip where it will appear is captured
/// and shown in a window above it (the menu sits on the pop-up menu layer, 101;
/// the cover on the screen-saver layer, 1000). The menu opens, is read and
/// closed underneath, and the cover stays up until its fade-out has finished:
/// measured at about 250 ms, well after the window list says it is gone.
/// Frosty's own menu is lifted above the cover as it opens.
///
/// Needs Screen Recording, and a private but long-stable CoreGraphics call to
/// set the level of Frosty's own menu window. Without either, `isAvailable` is
/// false and Frosty copies the menu the old way, with the flash.
enum FlashCover {
    /// How long the cover stays up after the Dock's menu is closed.
    static let fadeOut: TimeInterval = 0.35

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetWindowLevel = @convention(c) (Int32, UInt32, Int32) -> Int32

    private static let setLevel: (MainConnection, SetWindowLevel)? = {
        let handle = dlopen(nil, RTLD_NOW)
        guard let main = dlsym(handle, "CGSMainConnectionID"), let set = dlsym(handle, "CGSSetWindowLevel") else { return nil }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(set, to: SetWindowLevel.self))
    }()

    private static let coverLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static var isAvailable: Bool { hasPermission && setLevel != nil }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// Covers `rect` (AppKit coordinates, main screen) with a still of what is
    /// there now. Calls back on the main thread with the cover, or nil if the
    /// capture failed.
    static func cover(_ rect: NSRect, completion: @escaping (NSWindow?) -> Void) {
        guard let screen = NSScreen.screens.first else { return completion(nil) }
        let rect = rect.intersection(screen.frame).integral
        // ScreenCaptureKit measures from the top-left.
        let source = CGRect(x: rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        Task {
            let image = try? await capture(source, scale: screen.backingScaleFactor)
            await MainActor.run {
                guard let image else { return completion(nil) }
                let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                window.level = NSWindow.Level(rawValue: coverLevel)
                window.ignoresMouseEvents = true
                window.hasShadow = false
                window.isReleasedWhenClosed = false
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                let view = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
                view.image = NSImage(cgImage: image, size: rect.size)
                view.imageScaling = .scaleAxesIndependently
                window.contentView = view
                window.orderFrontRegardless()
                window.display()
                CATransaction.flush()
                completion(window)
            }
        }
    }

    private static func capture(_ source: CGRect, scale: CGFloat) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return nil }
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(source.width * scale)
        config.height = Int(source.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
    }

    /// Puts Frosty's open menus above the cover. Called just after a menu opens.
    static func liftMenus() {
        guard let (main, set) = setLevel,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == getpid()
                            && (w[kCGWindowLayer as String] as? Int) == menuLayer {
            if let number = w[kCGWindowNumber as String] as? UInt32 {
                _ = set(main(), number, Int32(coverLevel + 1))
            }
        }
    }
}
