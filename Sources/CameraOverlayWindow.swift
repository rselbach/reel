import AVFoundation
import SwiftUI

/// Floating window that displays the draggable camera overlay during recording.
/// Configured with `sharingType = .none` so it's excluded from screen capture.
final class CameraOverlayWindow: NSWindow {
    init(contentRect: NSRect) {
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
        // Prevent immediate deallocation on close() - fixes crash during recording stop
        isReleasedWhenClosed = false
    }
}

/// SwiftUI view that displays a draggable camera preview.
struct DraggableCameraOverlay: View {
    let sessionHolder: SessionHolder
    let size: CGFloat
    let shape: AppSettings.CameraOverlayShape
    let bounds: CGRect
    let onPositionChanged: (CGFloat, CGFloat) -> Void
    
    @State private var position: CGPoint
    @State private var isDragging = false
    
    init(
        sessionHolder: SessionHolder,
        size: CGFloat,
        shape: AppSettings.CameraOverlayShape,
        bounds: CGRect,
        initialPosition: CGPoint,
        onPositionChanged: @escaping (CGFloat, CGFloat) -> Void
    ) {
        self.sessionHolder = sessionHolder
        self.size = size
        self.shape = shape
        self.bounds = bounds
        self.onPositionChanged = onPositionChanged
        self._position = State(initialValue: initialPosition)
    }
    
    var body: some View {
        CameraPreviewView(sessionHolder: sessionHolder, size: size, shape: shape)
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            .scaleEffect(isDragging ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .position(position)
            .gesture(dragGesture)
    }
    
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                position = clampedPosition(value.location)
                notifyPositionChange()
            }
            .onEnded { _ in
                isDragging = false
            }
    }
    
    /// Clamps position to keep the overlay fully within bounds.
    private func clampedPosition(_ point: CGPoint) -> CGPoint {
        let halfSize = size / 2
        let minX = bounds.minX + halfSize
        let maxX = bounds.maxX - halfSize
        let minY = bounds.minY + halfSize
        let maxY = bounds.maxY - halfSize
        
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }
    
    /// Converts current position to normalized coordinates and notifies callback.
    private func notifyPositionChange() {
        let halfSize = size / 2
        let availableWidth = bounds.width - size
        let availableHeight = bounds.height - size
        
        guard availableWidth > 0, availableHeight > 0 else { return }
        
        // Convert from center position to normalized 0-1 range
        let normalizedX = (position.x - bounds.minX - halfSize) / availableWidth
        let normalizedY = (position.y - bounds.minY - halfSize) / availableHeight
        
        // Note: SwiftUI uses top-left origin, but Core Image uses bottom-left.
        // Flip Y so 0 = bottom, 1 = top (matching compositeFrame expectations)
        onPositionChanged(normalizedX, 1.0 - normalizedY)
    }
}

/// Controller that manages the camera overlay window lifecycle.
@MainActor
final class CameraOverlayController {
    private var window: CameraOverlayWindow?
    private var sessionHolder: SessionHolder?
    
    /// Shows the camera overlay window.
    /// - Parameters:
    ///   - session: The camera capture session to display
    ///   - bounds: The recording bounds (display or window frame)
    ///   - initialPosition: Corner preset for initial placement
    ///   - size: Overlay size setting
    ///   - shape: Overlay shape (circle or rectangle)
    ///   - onPositionChanged: Called with normalized (x, y) when user drags
    func show(
        session: AVCaptureSession,
        bounds: CGRect,
        initialPosition: AppSettings.CameraOverlayPosition,
        size: AppSettings.CameraOverlaySize,
        shape: AppSettings.CameraOverlayShape,
        onPositionChanged: @escaping (CGFloat, CGFloat) -> Void
    ) {
        // Calculate overlay size in points
        let overlaySize = bounds.width * size.fraction
        
        // Convert normalized position to absolute coordinates
        let coords = initialPosition.normalizedCoordinates
        let absolutePosition = absolutePositionFromNormalized(
            x: coords.x,
            y: coords.y,
            overlaySize: overlaySize,
            bounds: bounds
        )
        
        // Create window covering the recording bounds
        let window = CameraOverlayWindow(contentRect: bounds)
        
        // Wrap session in holder so we can invalidate it before teardown
        let holder = SessionHolder(session: session)
        self.sessionHolder = holder
        
        let overlayView = DraggableCameraOverlay(
            sessionHolder: holder,
            size: overlaySize,
            shape: shape,
            bounds: CGRect(origin: .zero, size: bounds.size),
            initialPosition: CGPoint(
                x: absolutePosition.x - bounds.minX,
                y: absolutePosition.y - bounds.minY
            ),
            onPositionChanged: onPositionChanged
        )
        
        window.contentView = NSHostingView(rootView: overlayView)
        window.orderFrontRegardless()
        
        self.window = window
    }
    
    /// Hides and releases the overlay window.
    func hide() {
        // Invalidate session holder FIRST to disconnect CameraPreviewNSView from session
        // This must happen before the session is stopped/deallocated
        sessionHolder?.invalidate()
        sessionHolder = nil
        
        window?.contentView = nil
        window?.close()
        window = nil
    }
    
    /// Updates the recording bounds (e.g., when the target window moves).
    func updateBounds(_ newBounds: CGRect) {
        window?.setFrame(newBounds, display: true)
    }
    
    /// Converts normalized coordinates to absolute screen position.
    private func absolutePositionFromNormalized(
        x: CGFloat,
        y: CGFloat,
        overlaySize: CGFloat,
        bounds: CGRect
    ) -> CGPoint {
        let halfSize = overlaySize / 2
        let availableWidth = bounds.width - overlaySize
        let availableHeight = bounds.height - overlaySize
        
        // x/y are normalized 0-1, but y is Core Image coords (0=bottom, 1=top)
        // SwiftUI uses 0=top, so flip y
        let absoluteX = bounds.minX + halfSize + (x * availableWidth)
        let absoluteY = bounds.minY + halfSize + ((1.0 - y) * availableHeight)
        
        return CGPoint(x: absoluteX, y: absoluteY)
    }
}
