import AVFoundation
import SwiftUI

enum CameraOverlayResizeLogic {
    /// Session-only size limits as a fraction of the recording width; the
    /// persisted Small/Medium/Large presets (0.15–0.25) sit inside this range.
    static let minFraction: CGFloat = 0.08
    static let maxFraction: CGFloat = 0.5
    /// Size of the square corner regions that start a resize instead of a move.
    static let cornerHitSize: CGFloat = 18

    enum Corner {
        case bottomLeft
        case bottomRight
        case topLeft
        case topRight
    }

    /// Which resize corner (if any) a point in view coordinates (origin
    /// bottom-left) falls in. Returns nil in the middle and along edges, and
    /// when the bounds are so small the corner regions would overlap.
    static func corner(at point: CGPoint, in bounds: CGRect, hitSize: CGFloat = cornerHitSize) -> Corner? {
        let nearLeft = point.x <= bounds.minX + hitSize
        let nearRight = point.x >= bounds.maxX - hitSize
        let nearBottom = point.y <= bounds.minY + hitSize
        let nearTop = point.y >= bounds.maxY - hitSize

        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, false, true, false): return .bottomLeft
        case (false, true, true, false): return .bottomRight
        case (true, false, false, true): return .topLeft
        case (false, true, false, true): return .topRight
        default: return nil
        }
    }

    /// Effective min/max overlay side lengths for a given drag area. Clamping
    /// `minSide` to `maxSide` prevents wide, short bounds from inverting the
    /// range and locking corner resizing.
    static func sideBounds(for dragBounds: CGRect) -> (minSide: CGFloat, maxSide: CGFloat) {
        let maxSide = CameraOverlayLayout.overlaySize(
            sizeFraction: maxFraction,
            bounds: dragBounds
        )
        let minSide = min(dragBounds.width * minFraction, maxSide)
        return (minSide: minSide, maxSide: maxSide)
    }

    /// New square frame for a corner drag: the dominant axis of the drag
    /// drives the size, and the corner opposite the dragged one stays fixed.
    static func resizedFrame(
        corner: Corner,
        initialFrame: CGRect,
        deltaX: CGFloat,
        deltaY: CGFloat,
        minSide: CGFloat,
        maxSide: CGFloat
    ) -> CGRect {
        let outwardDx: CGFloat
        let outwardDy: CGFloat
        switch corner {
        case .topRight:
            outwardDx = deltaX
            outwardDy = deltaY
        case .topLeft:
            outwardDx = -deltaX
            outwardDy = deltaY
        case .bottomRight:
            outwardDx = deltaX
            outwardDy = -deltaY
        case .bottomLeft:
            outwardDx = -deltaX
            outwardDy = -deltaY
        }

        let effectiveMin = min(minSide, maxSide)
        let initialSide = initialFrame.width
        let candidate =
            abs(outwardDx) >= abs(outwardDy)
            ? initialSide + outwardDx
            : initialSide + outwardDy
        let side = min(max(candidate, effectiveMin), maxSide)

        switch corner {
        case .topRight:
            return CGRect(x: initialFrame.minX, y: initialFrame.minY, width: side, height: side)
        case .topLeft:
            return CGRect(x: initialFrame.maxX - side, y: initialFrame.minY, width: side, height: side)
        case .bottomRight:
            return CGRect(x: initialFrame.minX, y: initialFrame.maxY - side, width: side, height: side)
        case .bottomLeft:
            return CGRect(x: initialFrame.maxX - side, y: initialFrame.maxY - side, width: side, height: side)
        }
    }
}

enum CameraOverlayLayout {
    /// Corner radius of the rounded square, as a fraction of its side, so
    /// the preview and the recording round it the same at any size.
    static let cornerRadiusFraction: CGFloat = 0.16

    static func cornerRadius(side: CGFloat, shape: AppSettings.CameraOverlayShape) -> CGFloat {
        switch shape {
        case .circle:
            return side / 2
        case .roundedSquare:
            return (side * cornerRadiusFraction).rounded()
        }
    }

    static func overlaySize(sizeFraction: CGFloat, bounds: CGRect) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        return min(bounds.width * sizeFraction, bounds.width, bounds.height)
    }

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
    private var initialWindowFrame: NSRect = .zero
    private var resizingCorner: CameraOverlayResizeLogic.Corner?
    private var didResizeDrag = false
    var dragBounds: CGRect = .zero
    var overlaySize: CGFloat = 0
    var onPositionChanged: ((CGFloat, CGFloat) -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?
    /// Fired once when a corner-drag resize ends, for persisting the size.
    var onSizeChangeEnded: ((CGFloat) -> Void)?

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
        initialWindowFrame = frame
        didResizeDrag = false
        // A press near a corner starts a resize; anywhere else moves.
        resizingCorner = CameraOverlayResizeLogic.corner(
            at: event.locationInWindow,
            in: CGRect(origin: .zero, size: frame.size)
        )
    }

    override func mouseUp(with event: NSEvent) {
        if resizingCorner != nil, didResizeDrag, dragBounds.width > 0 {
            onSizeChangeEnded?(overlaySize / dragBounds.width)
        }
        resizingCorner = nil
        didResizeDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - initialMouseLocation.x
        let deltaY = currentMouse.y - initialMouseLocation.y

        if let corner = resizingCorner {
            resizeDrag(corner: corner, deltaX: deltaX, deltaY: deltaY)
            return
        }

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

    private func resizeDrag(corner: CameraOverlayResizeLogic.Corner, deltaX: CGFloat, deltaY: CGFloat) {
        if deltaX != 0 || deltaY != 0 {
            didResizeDrag = true
        }
        let limits = CameraOverlayResizeLogic.sideBounds(for: dragBounds)

        var newFrame = CameraOverlayResizeLogic.resizedFrame(
            corner: corner,
            initialFrame: initialWindowFrame,
            deltaX: deltaX,
            deltaY: deltaY,
            minSide: limits.minSide,
            maxSide: limits.maxSide
        )
        newFrame.origin.x = max(dragBounds.minX, min(newFrame.origin.x, dragBounds.maxX - newFrame.width))
        newFrame.origin.y = max(dragBounds.minY, min(newFrame.origin.y, dragBounds.maxY - newFrame.height))

        overlaySize = newFrame.width
        setFrame(newFrame, display: true)
        notifySizeChanged()
        notifyPositionChanged()
    }

    func notifyPositionChanged() {
        guard
            let position = CameraOverlayLayout.normalizedPosition(
                origin: frame.origin,
                overlaySize: overlaySize,
                bounds: dragBounds
            )
        else { return }

        onPositionChanged?(position.x, position.y)
    }

    func notifySizeChanged() {
        guard dragBounds.width > 0 else { return }
        onSizeChanged?(overlaySize / dragBounds.width)
    }

    func clampToDragBounds() {
        var newOrigin = frame.origin
        newOrigin.x = max(dragBounds.minX, min(newOrigin.x, dragBounds.maxX - overlaySize))
        newOrigin.y = max(dragBounds.minY, min(newOrigin.y, dragBounds.maxY - overlaySize))
        if newOrigin != frame.origin {
            setFrameOrigin(newOrigin)
        }
    }

    func fitSizeToDragBounds() {
        let maxSide = CameraOverlayLayout.overlaySize(
            sizeFraction: CameraOverlayResizeLogic.maxFraction,
            bounds: dragBounds
        )
        guard maxSide > 0, overlaySize > maxSide else { return }

        overlaySize = maxSide
        setFrame(
            CGRect(origin: frame.origin, size: CGSize(width: maxSide, height: maxSide)),
            display: true
        )
    }
}

/// Manages pushed diagonal resize cursors so leaving the overlay or closing it
/// restores the prior cursor without clobbering other apps' cursors.
@MainActor
final class ResizeCursorManager {
    private var activePosition: NSCursor.FrameResizePosition?

    func update(position: NSCursor.FrameResizePosition?) {
        guard position != activePosition else { return }
        if activePosition != nil {
            NSCursor.pop()
        }
        if let position {
            NSCursor.frameResize(position: position, directions: .all).push()
        }
        activePosition = position
    }

    func reset() {
        update(position: nil)
    }
}

/// Camera preview content (moving and resizing are handled by the window).
/// Fills the window, so it tracks live resizes. The hover chrome never
/// appears in recordings: the whole window is excluded from capture.
struct CameraOverlayContent: View {
    let sessionHolder: SessionHolder
    let shape: AppSettings.CameraOverlayShape
    let cursorManager: ResizeCursorManager
    @State private var isHovering = false

    init(
        sessionHolder: SessionHolder,
        shape: AppSettings.CameraOverlayShape,
        cursorManager: ResizeCursorManager = ResizeCursorManager()
    ) {
        self.sessionHolder = sessionHolder
        self.shape = shape
        self.cursorManager = cursorManager
    }

    var body: some View {
        GeometryReader { geometry in
            CameraPreviewView(sessionHolder: sessionHolder, shape: shape)
                .overlay {
                    if isHovering {
                        ResizeChrome(shape: shape)
                    }
                }
                .onHover { hovering in
                    isHovering = hovering
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        updateCursor(at: point, size: geometry.size)
                    case .ended:
                        cursorManager.reset()
                    }
                }
                .onDisappear {
                    cursorManager.reset()
                }
        }
        // No SwiftUI shadow: it filled the window's corners around the
        // bubble, and the window's own shadow already follows the shape.
    }

    /// Shows a diagonal resize cursor over the corner hit regions.
    /// SwiftUI local coordinates have a top-left origin, unlike the window's
    /// bottom-left hit test, so the Y coordinate is flipped before hit testing.
    private func updateCursor(at point: CGPoint, size: CGSize) {
        let flippedPoint = CGPoint(x: point.x, y: size.height - point.y)
        let corner = CameraOverlayResizeLogic.corner(
            at: flippedPoint,
            in: CGRect(origin: .zero, size: size)
        )

        let position: NSCursor.FrameResizePosition?
        switch corner {
        case .topLeft: position = .topLeft
        case .topRight: position = .topRight
        case .bottomLeft: position = .bottomLeft
        case .bottomRight: position = .bottomRight
        case .none: position = nil
        }

        cursorManager.update(position: position)
    }
}

/// Hover-only outline and corner dots advertising that the overlay can be
/// moved and corner-resized.
private struct ResizeChrome: View {
    let shape: AppSettings.CameraOverlayShape

    var body: some View {
        ZStack {
            outline
            cornerDot.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            cornerDot.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            cornerDot.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            cornerDot.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }

    private var outline: some View {
        CameraOverlayClipShape(shape: shape)
            .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
    }

    private var cornerDot: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 7, height: 7)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .padding(4)
    }
}

/// Controller that manages the camera overlay window lifecycle.
@MainActor
final class CameraOverlayController {
    private var window: CameraOverlayWindow?
    private var sessionHolder: SessionHolder?
    private let cursorManager = ResizeCursorManager()

    /// Shows the camera overlay window.
    func show(
        session: AVCaptureSession,
        bounds: CGRect,
        initialPosition: AppSettings.CameraOverlayPosition,
        sizeFraction: CGFloat,
        shape: AppSettings.CameraOverlayShape,
        onPositionChanged: @escaping (CGFloat, CGFloat) -> Void,
        onSizeChanged: @escaping (CGFloat) -> Void,
        onSizeChangeEnded: @escaping (CGFloat) -> Void
    ) {
        if window != nil || sessionHolder != nil {
            hide()
        }

        let overlaySize = CameraOverlayLayout.overlaySize(
            sizeFraction: sizeFraction,
            bounds: bounds
        )

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
        window.onSizeChanged = onSizeChanged
        window.onSizeChangeEnded = onSizeChangeEnded

        let holder = SessionHolder(session: session)
        self.sessionHolder = holder

        let content = CameraOverlayContent(
            sessionHolder: holder,
            shape: shape,
            cursorManager: cursorManager
        )
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()

        self.window = window
    }

    func hide() {
        cursorManager.reset()
        sessionHolder?.invalidate()
        sessionHolder = nil

        window?.contentView = nil
        window?.close()
        window = nil
    }

    /// Updates the drag bounds after the recorded window moved or resized,
    /// shifting the overlay by the same delta so it keeps its position
    /// relative to the recorded content, then re-clamping and republishing
    /// the normalized position for the compositor.
    func updateBounds(_ newBounds: CGRect) {
        guard let window, window.dragBounds != newBounds else { return }

        let delta = CGPoint(
            x: newBounds.minX - window.dragBounds.minX,
            y: newBounds.minY - window.dragBounds.minY
        )
        window.dragBounds = newBounds
        window.setFrameOrigin(
            NSPoint(
                x: window.frame.origin.x + delta.x,
                y: window.frame.origin.y + delta.y
            ))
        window.fitSizeToDragBounds()
        window.clampToDragBounds()
        window.notifyPositionChanged()
        // A recorded-window resize changes the bounds size, which changes the
        // overlay's fraction of the recording; keep the compositor in sync.
        window.notifySizeChanged()
    }
}
