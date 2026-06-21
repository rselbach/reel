import AVFoundation
import SwiftUI

enum CameraOverlayLayout {
    static func originFromNormalized(
        x: CGFloat,
        y: CGFloat,
        overlaySize: CGFloat,
        bounds: CGRect
    ) -> CGPoint {
        let availableWidth = bounds.width - overlaySize
        let availableHeight = bounds.height - overlaySize

        return CGPoint(
            x: bounds.minX + (x * availableWidth),
            y: bounds.minY + (y * availableHeight)
        )
    }

    static func normalizedPosition(
        origin: CGPoint,
        overlaySize: CGFloat,
        bounds: CGRect
    ) -> (x: CGFloat, y: CGFloat)? {
        let availableWidth = bounds.width - overlaySize
        let availableHeight = bounds.height - overlaySize

        guard availableWidth > 0, availableHeight > 0 else { return nil }

        return (
            x: (origin.x - bounds.minX) / availableWidth,
            y: (origin.y - bounds.minY) / availableHeight
        )
    }
}

/// Floating window sized exactly to the camera preview.
/// The window itself is dragged rather than using SwiftUI gestures.
final class CameraOverlayWindow: NSWindow {
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero
    var dragBounds: CGRect = .zero
    var overlaySize: CGFloat = 0
    var onPositionChanged: ((CGFloat, CGFloat) -> Void)?
    
    init(contentRect: NSRect, dragBounds: CGRect, overlaySize: CGFloat) {
        self.dragBounds = dragBounds
        self.overlaySize = overlaySize
        
        super.init(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        sharingType = .none  // Critical: excludes from screen capture
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isReleasedWhenClosed = false
        // Dragging is handled by mouseDown/mouseDragged below, which clamp to
        // dragBounds. Enabling isMovableByWindowBackground would let AppKit
        // also move the window without clamping, fighting the manual override.
        isMovableByWindowBackground = false
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = frame.origin
    }
    
    override func mouseDragged(with event: NSEvent) {
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - initialMouseLocation.x
        let deltaY = currentMouse.y - initialMouseLocation.y
        
        var newOrigin = NSPoint(
            x: initialWindowOrigin.x + deltaX,
            y: initialWindowOrigin.y + deltaY
        )
        
        // Clamp to drag bounds
        newOrigin.x = max(dragBounds.minX, min(newOrigin.x, dragBounds.maxX - overlaySize))
        newOrigin.y = max(dragBounds.minY, min(newOrigin.y, dragBounds.maxY - overlaySize))
        
        setFrameOrigin(newOrigin)
        notifyPositionChanged()
    }
    
    private func notifyPositionChanged() {
        guard let position = CameraOverlayLayout.normalizedPosition(
            origin: frame.origin,
            overlaySize: overlaySize,
            bounds: dragBounds
        ) else { return }

        onPositionChanged?(position.x, position.y)
    }
}

/// Simple camera preview view (no drag gesture, window handles that).
struct CameraOverlayContent: View {
    let sessionHolder: SessionHolder
    let size: CGFloat
    let shape: AppSettings.CameraOverlayShape
    
    var body: some View {
        CameraPreviewView(sessionHolder: sessionHolder, size: size, shape: shape)
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

/// Controller that manages the camera overlay window lifecycle.
@MainActor
final class CameraOverlayController {
    private var window: CameraOverlayWindow?
    private var sessionHolder: SessionHolder?
    
    /// Shows the camera overlay window.
    func show(
        session: AVCaptureSession,
        bounds: CGRect,
        initialPosition: AppSettings.CameraOverlayPosition,
        size: AppSettings.CameraOverlaySize,
        shape: AppSettings.CameraOverlayShape,
        onPositionChanged: @escaping (CGFloat, CGFloat) -> Void
    ) {
        let overlaySize = bounds.width * size.fraction
        
        // Convert normalized position to screen coordinates
        let coords = initialPosition.normalizedCoordinates
        let windowOrigin = CameraOverlayLayout.originFromNormalized(
            x: coords.x,
            y: coords.y,
            overlaySize: overlaySize,
            bounds: bounds
        )
        
        let windowFrame = CGRect(origin: windowOrigin, size: CGSize(width: overlaySize, height: overlaySize))
        let window = CameraOverlayWindow(contentRect: windowFrame, dragBounds: bounds, overlaySize: overlaySize)
        window.onPositionChanged = onPositionChanged
        
        let holder = SessionHolder(session: session)
        self.sessionHolder = holder
        
        let content = CameraOverlayContent(sessionHolder: holder, size: overlaySize, shape: shape)
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()
        
        self.window = window
    }
    
    func hide() {
        sessionHolder?.invalidate()
        sessionHolder = nil
        
        window?.contentView = nil
        window?.close()
        window = nil
    }
    
    func updateBounds(_ newBounds: CGRect) {
        window?.dragBounds = newBounds
    }
}
