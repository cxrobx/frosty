import AppKit

/// Reserves a strip of the screen the way the real Dock does, so maximize,
/// Fill and window tiling stop at Frosty's bar instead of running under it.
///
/// The Dock tells the window server its strip with a private SkyLight call,
/// `SLSSetDockRectWithOrientation`, and the window server takes it from any
/// app. The Dock repeats the call when it relaunches, when a display changes
/// and at other times it doesn't announce, replacing Frosty's strip, so the
/// bar checks with `isInPlace` and sets it again (`reassert`).
///
/// A strip can't be taken back: a zero-height one is ignored and a 1 pt one
/// still reserves 1 pt. Restarting the Dock makes it report its own strip
/// again, which is the exact undo, so clearing does that.
final class ScreenReservation {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetDockRect = @convention(c) (Int32, CGRect, Int32, Int32) -> Int32
    private typealias GetDockRect = @convention(c) (Int32, UnsafeMutablePointer<CGRect>,
                                                    UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    private static let skyLight: (main: MainConnection, set: SetDockRect, get: GetDockRect)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let set = dlsym(handle, "SLSSetDockRectWithOrientation"),
              let get = dlsym(handle, "SLSGetDockRectWithOrientation") else { return nil }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(set, to: SetDockRect.self),
                unsafeBitCast(get, to: GetDockRect.self))
    }()

    /// What the Dock passes with its strip: why it changed (1, a layout) and
    /// which edge it is on (2, the bottom).
    private static let reason: Int32 = 1
    private static let bottom: Int32 = 2

    /// The strip Frosty last reserved (window server coordinates), or nil.
    private(set) var current: CGRect?
    private let restartDock: () -> Void

    init(restartDock: @escaping () -> Void) {
        self.restartDock = restartDock
    }

    /// Reserves `rect`, or clears Frosty's strip when nil. Does nothing if
    /// that is already the case.
    func set(_ rect: CGRect?) {
        guard rect != current else { return }
        if let rect {
            guard apply(rect) else { return }
            current = rect
        } else {
            current = nil
            restartDock()
        }
    }

    /// Sets the strip again after the Dock has replaced it with its own.
    func reassert() {
        if let current { _ = apply(current) }
    }

    /// Whether the window server still has Frosty's strip.
    var isInPlace: Bool {
        guard let current, let sky = Self.skyLight else { return true }
        var rect = CGRect.zero, reason: Int32 = 0, orientation: Int32 = 0
        guard sky.get(sky.main(), &rect, &reason, &orientation) == 0 else { return true }
        return rect == current
    }

    /// Frosty's strip is already gone, because the Dock was restarted for
    /// another reason (restoring its settings).
    func forget() {
        current = nil
    }

    private func apply(_ rect: CGRect) -> Bool {
        guard let sky = Self.skyLight else { return false }
        return sky.set(sky.main(), rect, Self.reason, Self.bottom) == 0
    }
}
