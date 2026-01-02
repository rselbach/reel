import AppKit
import ScreenCaptureKit

@MainActor
class WindowPicker: NSObject {
    private var overlayWindows: [NSWindow] = []
    private var highlightWindow: NSWindow?
    private var currentHoveredWindow: SCWindow?
    private var availableWindows: [SCWindow] = []
    private var windowIDSet: Set<CGWindowID> = []
    
    var onWindowSelected: ((SCWindow) -> Void)?
    var onCancelled: (() -> Void)?
    
    func start(with windows: [SCWindow]) {
        availableWindows = windows
        windowIDSet = Set(windows.map { $0.windowID })
        
        let cursor = createCameraCursor() ?? NSCursor.crosshair
        createOverlayWindows(cursor: cursor)
        createHighlightWindow()
    }
    
    private func createCameraCursor() -> NSCursor? {
        let size: CGFloat = 24
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let symbolImage = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        
        let imageSize = NSSize(width: size + 8, height: size + 8)
        let cursorImage = NSImage(size: imageSize, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            
            symbolImage.draw(
                in: NSRect(x: 4, y: 4, width: size, height: size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
        
        return NSCursor(image: cursorImage, hotSpot: NSPoint(x: imageSize.width / 2, y: imageSize.height / 2))
    }
    
    private func createOverlayWindows(cursor: NSCursor) {
        for screen in NSScreen.screens {
            let overlay = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            overlay.level = .screenSaver
            overlay.backgroundColor = NSColor.black.withAlphaComponent(0.3)
            overlay.isOpaque = false
            overlay.hasShadow = false
            overlay.ignoresMouseEvents = false
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
            let trackingView = PickerTrackingView(frame: screen.frame)
            trackingView.customCursor = cursor
            trackingView.onMouseMoved = { [weak self] point in
                self?.handleMouseMoved(to: point)
            }
            trackingView.onMouseClicked = { [weak self] point in
                self?.handleMouseClicked(at: point)
            }
            trackingView.onEscape = { [weak self] in
                self?.cancel()
            }
            
            overlay.contentView = trackingView
            overlay.makeKeyAndOrderFront(nil)
            overlayWindows.append(overlay)
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func createHighlightWindow() {
        let highlight = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        highlight.level = .screenSaver + 1
        highlight.backgroundColor = .clear
        highlight.isOpaque = false
        highlight.hasShadow = false
        highlight.ignoresMouseEvents = true
        
        let highlightView = HighlightView(frame: .zero)
        highlight.contentView = highlightView
        
        highlightWindow = highlight
    }
    
    private func handleMouseMoved(to point: NSPoint) {
        // Find the primary screen (origin of global coordinate system)
        guard let primaryScreen = NSScreen.screens.first else { return }

        // Convert from NSScreen coordinates (origin bottom-left of primary)
        // to CGWindow coordinates (origin top-left of primary)
        let flippedPoint = CGPoint(
            x: point.x,
            y: primaryScreen.frame.height - point.y
        )

        let foundWindow = findTopmostWindow(at: flippedPoint)

        if let window = foundWindow, window.windowID != currentHoveredWindow?.windowID {
            currentHoveredWindow = window
            showHighlight(for: window)
        } else if foundWindow == nil && currentHoveredWindow != nil {
            currentHoveredWindow = nil
            hideHighlight()
        }
    }
    
    private func findTopmostWindow(at point: CGPoint) -> SCWindow? {
        let windowListInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        
        for windowInfo in windowListInfo {
            guard let windowID = windowInfo[kCGWindowNumber] as? CGWindowID,
                  let layer = windowInfo[kCGWindowLayer] as? Int,
                  layer == 0,
                  windowIDSet.contains(windowID),
                  let boundsDict = windowInfo[kCGWindowBounds] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"]
            else { continue }
            
            let frame = CGRect(x: x, y: y, width: width, height: height)
            if frame.contains(point) {
                return availableWindows.first { $0.windowID == windowID }
            }
        }
        
        return nil
    }
    
    private func showHighlight(for window: SCWindow) {
        // Use primary screen for coordinate conversion (same as CGWindow coordinate system)
        guard let primaryScreen = NSScreen.screens.first else { return }

        let frame = window.frame
        // Convert from CGWindow coords (origin top-left) to NSScreen coords (origin bottom-left)
        let flippedFrame = CGRect(
            x: frame.origin.x,
            y: primaryScreen.frame.height - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )

        highlightWindow?.setFrame(flippedFrame, display: true)
        highlightWindow?.orderFront(nil)

        if let view = highlightWindow?.contentView as? HighlightView {
            let appName = window.owningApplication?.applicationName ?? "Unknown"
            let title = window.title ?? ""
            view.windowTitle = title.isEmpty ? appName : "\(appName) - \(title)"
            view.needsDisplay = true
        }
    }
    
    private func hideHighlight() {
        highlightWindow?.orderOut(nil)
    }
    
    private func handleMouseClicked(at point: NSPoint) {
        if let window = currentHoveredWindow {
            cleanup()
            onWindowSelected?(window)
        }
    }
    
    private func cancel() {
        cleanup()
        onCancelled?()
    }
    
    private func cleanup() {
        NSCursor.arrow.set()
        hideHighlight()
        highlightWindow = nil
        
        for overlay in overlayWindows {
            overlay.orderOut(nil)
        }
        overlayWindows.removeAll()
        
        currentHoveredWindow = nil
        availableWindows.removeAll()
        windowIDSet.removeAll()
    }
}

class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class PickerTrackingView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseClicked: ((NSPoint) -> Void)?
    var onEscape: (() -> Void)?
    var customCursor: NSCursor?
    
    private var trackingArea: NSTrackingArea?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }
    
    override func cursorUpdate(with event: NSEvent) {
        customCursor?.set()
    }
    
    override func resetCursorRects() {
        if let cursor = customCursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    
    override func mouseMoved(with event: NSEvent) {
        customCursor?.set()
        let location = NSEvent.mouseLocation
        onMouseMoved?(location)
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        onMouseClicked?(location)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape {
            onEscape?()
        }
    }
}

class HighlightView: NSView {
    var windowTitle: String = ""
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let borderWidth: CGFloat = 4
        let borderRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(roundedRect: borderRect, xRadius: 8, yRadius: 8)
        path.lineWidth = borderWidth
        path.stroke()
        
        // draw title badge at top
        if !windowTitle.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = windowTitle.size(withAttributes: attrs)
            let padding: CGFloat = 12
            let badgeWidth = size.width + padding * 2
            let badgeHeight = size.height + 8
            
            let badgeRect = CGRect(
                x: (bounds.width - badgeWidth) / 2,
                y: bounds.height - badgeHeight - 8,
                width: badgeWidth,
                height: badgeHeight
            )
            
            NSColor.systemBlue.setFill()
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
            badgePath.fill()
            
            let textRect = CGRect(
                x: badgeRect.origin.x + padding,
                y: badgeRect.origin.y + 4,
                width: size.width,
                height: size.height
            )
            windowTitle.draw(in: textRect, withAttributes: attrs)
        }
    }
}
