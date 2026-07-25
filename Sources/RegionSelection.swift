import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "RegionSelection")

enum RegionMath {
    /// Selections smaller than this (in points) are treated as stray clicks.
    static let minimumSelectionSize: CGFloat = 20

    /// Converts a selection rect in a screen's local Cocoa coordinates
    /// (origin bottom-left, Y up) to display-local Quartz coordinates (origin
    /// top-left, Y down) — the space SCStreamConfiguration.sourceRect expects.
    static func quartzRect(fromScreenLocalCocoa rect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: screenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Places a display-local Quartz region into global Quartz space.
    static func globalQuartzFrame(regionRect: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + regionRect.minX,
            y: displayFrame.minY + regionRect.minY,
            width: regionRect.width,
            height: regionRect.height
        )
    }
}

enum RegionSelectionLabel {
    static let margin: CGFloat = 8
    static let padding = CGSize(width: 10, height: 5)

    static func text(for rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    /// Puts the readout just above the selection, flipping to just below when
    /// the selection is close enough to the top that it would be clipped.
    static func origin(for rect: CGRect, labelSize: CGSize, in bounds: CGRect) -> CGPoint {
        let above = rect.maxY + margin
        let fitsAbove = above + labelSize.height <= bounds.maxY
        let y = fitsAbove ? above : max(bounds.minY, rect.maxY - labelSize.height - margin)
        let x = min(
            max(bounds.minX, rect.midX - labelSize.width / 2),
            max(bounds.minX, bounds.maxX - labelSize.width)
        )
        return CGPoint(x: x, y: y)
    }
}

enum RegionAdjustment {
    /// How close to an edge counts as grabbing a corner rather than the body.
    static let handleHitSize: CGFloat = 14

    enum Handle: Equatable {
        case bottomLeft
        case bottomRight
        case topLeft
        case topRight
        case move
    }

    static func handle(at point: CGPoint, in rect: CGRect, hitSize: CGFloat = handleHitSize) -> Handle? {
        guard rect.insetBy(dx: -hitSize, dy: -hitSize).contains(point) else { return nil }

        let nearLeft = abs(point.x - rect.minX) <= hitSize
        let nearRight = abs(point.x - rect.maxX) <= hitSize
        let nearBottom = abs(point.y - rect.minY) <= hitSize
        let nearTop = abs(point.y - rect.maxY) <= hitSize

        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, true, _): return .bottomLeft
        case (_, true, true, _): return .bottomRight
        case (true, _, _, true): return .topLeft
        case (_, true, _, true): return .topRight
        default: return rect.contains(point) ? .move : nil
        }
    }

    /// Applies a drag to the selection, keeping it at least minimumSize on
    /// each edge and entirely within the screen.
    static func adjusted(
        rect: CGRect,
        handle: Handle,
        delta: CGPoint,
        bounds: CGRect,
        minimumSize: CGFloat
    ) -> CGRect {
        var result: CGRect
        switch handle {
        case .move:
            result = rect.offsetBy(dx: delta.x, dy: delta.y)
        case .bottomLeft:
            result = CGRect(
                x: rect.minX + delta.x,
                y: rect.minY + delta.y,
                width: rect.width - delta.x,
                height: rect.height - delta.y
            )
        case .bottomRight:
            result = CGRect(
                x: rect.minX,
                y: rect.minY + delta.y,
                width: rect.width + delta.x,
                height: rect.height - delta.y
            )
        case .topLeft:
            result = CGRect(
                x: rect.minX + delta.x,
                y: rect.minY,
                width: rect.width - delta.x,
                height: rect.height + delta.y
            )
        case .topRight:
            result = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width + delta.x,
                height: rect.height + delta.y
            )
        }

        // A drag past the opposite edge flips the rect; standardizing keeps
        // the result well formed instead of negative.
        result = result.standardized
        result.size.width = min(max(minimumSize, result.width), bounds.width)
        result.size.height = min(max(minimumSize, result.height), bounds.height)
        result.origin.x = min(max(bounds.minX, result.minX), bounds.maxX - result.width)
        result.origin.y = min(max(bounds.minY, result.minY), bounds.maxY - result.height)
        return result
    }
}

/// A user-selected screen region to record.
struct RecordingRegion: Equatable {
    let displayID: CGDirectDisplayID
    /// Display-local Quartz rect (origin top-left), in points.
    let rect: CGRect

    init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect
    }

    init?(screen: NSScreen, screenLocalCocoaRect: CGRect) {
        guard let displayID = screen.displayID else { return nil }
        self.displayID = displayID
        self.rect = RegionMath.quartzRect(
            fromScreenLocalCocoa: screenLocalCocoaRect,
            screenHeight: screen.frame.height
        )
    }
}

/// Full-screen drag-to-select overlay, one window per display.
@MainActor
final class RegionSelector {
    private var windows: [RegionSelectionWindow] = []
    private var continuation: CheckedContinuation<RecordingRegion?, Never>?

    /// Presents the selection overlays and resolves with the chosen region,
    /// or nil when the user cancels with Esc.
    func select() async -> RecordingRegion? {
        guard continuation == nil else { return nil }
        guard !NSScreen.screens.isEmpty else {
            logger.error("Cannot select region: no screens available")
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let window = RegionSelectionWindow(screen: screen)
                window.onSelection = { [weak self] rect in
                    guard let region = RecordingRegion(screen: screen, screenLocalCocoaRect: rect) else {
                        logger.error("Selected screen has no display ID; cancelling region selection")
                        self?.finish(with: nil)
                        return
                    }
                    self?.finish(with: region)
                }
                window.onCancel = { [weak self] in
                    self?.finish(with: nil)
                }
                window.makeKeyAndOrderFront(nil)
                windows.append(window)
            }
        }
    }

    private func finish(with region: RecordingRegion?) {
        guard let continuation else { return }
        self.continuation = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        continuation.resume(returning: region)
    }
}

final class RegionSelectionWindow: NSWindow {
    var onSelection: ((CGRect) -> Void)? {
        get { selectionView?.onSelection }
        set { selectionView?.onSelection = newValue }
    }

    var onCancel: (() -> Void)? {
        get { selectionView?.onCancel }
        set { selectionView?.onCancel = newValue }
    }

    private var selectionView: RegionSelectionView? {
        contentView as? RegionSelectionView
    }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard selectionView?.handleKeyDown(event) == true else {
            super.keyDown(with: event)
            return
        }
    }
}

final class RegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private enum Phase {
        case idle
        /// Dragging out a new selection.
        case drawing
        /// Selection drawn; the user can nudge it before committing.
        case adjusting
    }

    private var phase: Phase = .idle
    private var startPoint: NSPoint?
    private var currentRect: CGRect?
    private var activeHandle: RegionAdjustment.Handle?
    private var handleDragOrigin: CGPoint?
    private var rectAtHandleDragStart: CGRect?
    private let hintLabel: NSTextField

    private enum Hint {
        static let draw = "Drag to select the area to record — Esc to cancel"
        static let adjust = "Drag to adjust — Return to record, Esc to cancel"
    }

    override init(frame frameRect: NSRect) {
        hintLabel = NSTextField(labelWithString: Hint.draw)
        super.init(frame: frameRect)

        hintLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        hintLabel.drawsBackground = true
        hintLabel.alignment = .center
        hintLabel.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        addSubview(hintLabel)
        layoutHint()
    }

    required init?(coder: NSCoder) {
        hintLabel = NSTextField(labelWithString: "")
        super.init(coder: coder)
    }

    private func layoutHint() {
        hintLabel.sizeToFit()
        hintLabel.frame = NSRect(
            x: (bounds.width - hintLabel.frame.width - 24) / 2,
            y: bounds.height - 80,
            width: hintLabel.frame.width + 24,
            height: hintLabel.frame.height + 12
        )
    }

    private func showHint(_ text: String) {
        hintLabel.stringValue = text
        hintLabel.isHidden = false
        layoutHint()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // A double-click inside a drawn selection is the fast path to record.
        if phase == .adjusting, event.clickCount >= 2, let rect = currentRect, rect.contains(point) {
            commit()
            return
        }

        // Grabbing the selection or one of its corners adjusts it; anywhere
        // else starts a fresh selection.
        if phase == .adjusting,
           let rect = currentRect,
           let handle = RegionAdjustment.handle(at: point, in: rect) {
            activeHandle = handle
            handleDragOrigin = point
            rectAtHandleDragStart = rect
            return
        }

        phase = .drawing
        startPoint = point
        currentRect = nil
        activeHandle = nil
        hintLabel.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let handle = activeHandle,
           let origin = handleDragOrigin,
           let rect = rectAtHandleDragStart {
            currentRect = RegionAdjustment.adjusted(
                rect: rect,
                handle: handle,
                delta: CGPoint(x: point.x - origin.x, y: point.y - origin.y),
                bounds: bounds,
                minimumSize: RegionMath.minimumSelectionSize
            )
            needsDisplay = true
            return
        }

        guard let startPoint else { return }
        currentRect = CGRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(point.x - startPoint.x),
            height: abs(point.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if activeHandle != nil {
            activeHandle = nil
            handleDragOrigin = nil
            rectAtHandleDragStart = nil
            return
        }

        startPoint = nil

        guard let rect = currentRect,
              rect.width >= RegionMath.minimumSelectionSize,
              rect.height >= RegionMath.minimumSelectionSize else {
            // Stray click or tiny drag: keep waiting for a real selection.
            currentRect = nil
            phase = .idle
            showHint(Hint.draw)
            needsDisplay = true
            return
        }

        // Drawing no longer commits: the selection stays put so it can be
        // nudged into place before recording starts.
        phase = .adjusting
        showHint(Hint.adjust)
        needsDisplay = true
    }

    /// Called by the window, which owns key handling.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.escape:
            onCancel?()
            return true
        case KeyCode.return:
            guard phase == .adjusting else { return true }
            commit()
            return true
        default:
            return false
        }
    }

    private func commit() {
        guard let rect = currentRect else { return }
        onSelection?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard let rect = currentRect else { return }

        // Punch the selection out of the dimmed layer, then outline it.
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        path.lineWidth = 2
        path.stroke()

        if phase == .adjusting {
            drawHandles(for: rect)
        }
        drawSizeReadout(for: rect)
    }

    /// Corner dots, so it is obvious the selection can still be changed.
    private func drawHandles(for rect: CGRect) {
        let size: CGFloat = 8
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]

        for corner in corners {
            let dot = CGRect(
                x: corner.x - size / 2,
                y: corner.y - size / 2,
                width: size,
                height: size
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(ovalIn: dot)
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    /// Demo recordings are usually uploaded somewhere with a target size, so
    /// the exact dimensions matter while the area is being drawn.
    private func drawSizeReadout(for rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = RegionSelectionLabel.text(for: rect) as NSString
        let textSize = text.size(withAttributes: attributes)
        let labelSize = CGSize(
            width: textSize.width + RegionSelectionLabel.padding.width * 2,
            height: textSize.height + RegionSelectionLabel.padding.height * 2
        )
        let origin = RegionSelectionLabel.origin(for: rect, labelSize: labelSize, in: bounds)
        let labelRect = CGRect(origin: origin, size: labelSize)

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()

        text.draw(
            at: CGPoint(
                x: labelRect.minX + RegionSelectionLabel.padding.width,
                y: labelRect.minY + RegionSelectionLabel.padding.height
            ),
            withAttributes: attributes
        )
    }
}

/// Non-interactive border drawn around whatever is being captured — an area
/// or a window — while recording. Excluded from capture via sharingType, so it
/// never appears in the file.
@MainActor
final class CaptureBoundsIndicator {
    private var window: NSWindow?

    func show(globalQuartzFrame: CGRect) {
        guard let cocoaFrame = cocoaRect(fromQuartz: globalQuartzFrame) else {
            logger.error("Cannot show capture bounds: no screens for coordinate conversion")
            return
        }

        let window = NSWindow(
            contentRect: cocoaFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = CaptureBoundsView(frame: NSRect(origin: .zero, size: cocoaFrame.size))
        window.orderFrontRegardless()

        self.window = window
    }

    /// Follows the recorded window as it is moved or resized.
    func update(globalQuartzFrame: CGRect) {
        guard let window,
              let cocoaFrame = cocoaRect(fromQuartz: globalQuartzFrame),
              window.frame != cocoaFrame else {
            return
        }
        window.setFrame(cocoaFrame, display: true)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

final class CaptureBoundsView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
