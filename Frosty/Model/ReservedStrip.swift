import CoreGraphics

/// The strip along the bottom of a display that the window server keeps
/// maximized, filled and tiled windows out of, as it does for the real Dock.
enum ReservedStrip {
    /// The strip `height` points tall at the bottom of `screen` (AppKit
    /// coordinates), in the window server's coordinates: measured from the top
    /// left of the display with the menu bar, which is `primaryHeight` tall.
    static func rect(bottomOf screen: CGRect, height: CGFloat, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: screen.minX, y: primaryHeight - screen.minY - height, width: screen.width, height: height)
    }
}
