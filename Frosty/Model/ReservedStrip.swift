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

    /// The height that stops a window above `strip`, if the window was filled
    /// or tiled into it: its bottom edge sits exactly on the bottom of the
    /// screen the strip is on. A window dragged partly off the bottom, one on
    /// another display, or one that would end up too short is left alone.
    /// Everything is in window server coordinates (y grows downward).
    static func trimmedHeight(windowTop: CGFloat, windowHeight: CGFloat, windowMinX: CGFloat, windowMaxX: CGFloat,
                              strip: CGRect) -> CGFloat? {
        let bottom = windowTop + windowHeight
        guard abs(bottom - strip.maxY) <= 1,
              windowMaxX > strip.minX, windowMinX < strip.maxX,
              strip.minY - windowTop >= minimumHeight else { return nil }
        return strip.minY - windowTop
    }

    static let minimumHeight: CGFloat = 100
}
