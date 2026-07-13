import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

enum ScreenCoordinateConversion {
    static func cocoaRect(fromQuartz frame: CGRect, primaryScreenFrame: CGRect) -> NSRect {
        NSRect(
            x: frame.origin.x,
            y: primaryScreenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

/// Converts a Quartz coordinate rect (origin top-left, Y down — used by
/// `SCDisplay.frame` / `SCWindow.frame`) to a Cocoa coordinate rect (origin
/// bottom-left, Y up — used by `NSWindow`).
///
/// Both coordinate systems are anchored to the primary display, so its frame
/// provides the vertical flip axis even when another display sits above it.
/// Returns nil if no primary screen is available.
func cocoaRect(fromQuartz frame: CGRect) -> NSRect? {
    guard let primaryScreen = NSScreen.screens.first else { return nil }
    return ScreenCoordinateConversion.cocoaRect(
        fromQuartz: frame,
        primaryScreenFrame: primaryScreen.frame
    )
}
