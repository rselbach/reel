import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Converts a Quartz coordinate rect (origin top-left, Y down — used by
/// `SCDisplay.frame` / `SCWindow.frame`) to a Cocoa coordinate rect (origin
/// bottom-left, Y up — used by `NSWindow`).
///
/// Uses the full virtual desktop height so placement is correct across
/// horizontally and vertically stacked displays. Returns nil if no screens
/// are available to compute the desktop bounds.
func cocoaRect(fromQuartz frame: CGRect) -> NSRect? {
    guard !NSScreen.screens.isEmpty else { return nil }
    let desktopBounds = NSScreen.screens.reduce(into: CGRect.null) { partial, screen in
        partial = partial.union(screen.frame)
    }
    return NSRect(
        x: frame.origin.x,
        y: desktopBounds.maxY - frame.origin.y - frame.height,
        width: frame.width,
        height: frame.height
    )
}
