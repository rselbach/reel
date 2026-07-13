import AppKit

// Explicit AppKit bootstrap. Reel is a menu bar app whose windows are all
// AppDelegate-managed NSWindows; the previous SwiftUI App lifecycle existed
// only to satisfy the Scene requirement and registered an empty Settings
// scene — a second, blank settings window if ever triggered.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Accessory keeps Reel out of the Dock even in unbundled dev builds, where
// there is no Info.plist to declare LSUIElement.
app.setActivationPolicy(.accessory)
app.run()
