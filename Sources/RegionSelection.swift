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

    @MainActor
    static func text(
        for rect: CGRect,
        backingScaleFactor: CGFloat,
        maxHeight: CGFloat?,
        codec: AppSettings.VideoCodec
    ) -> String {
        let dimensions = ScreenRecorder.outputDimensions(
            width: Int(rect.width * backingScaleFactor),
            height: Int(rect.height * backingScaleFactor),
            maxHeight: maxHeight,
            codec: codec
        )
        return "\(dimensions.width) × \(dimensions.height) px"
    }

    /// Puts the readout just above the selection, tucking it inside the top edge
    /// when the selection is close enough to the top that it would be clipped.
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

enum RegionAspectConstraint {
    /// Held while dragging to lock the selection to the shape most demo
    /// recordings are eventually shown at.
    static let ratio: CGFloat = 16.0 / 9.0
    static let label = "16:9"

    /// Builds a ratio-locked rect between the anchor and the pointer. The
    /// dominant axis of the drag drives the size, so the selection follows
    /// whichever direction the user is actually pulling.
    static func rect(anchor: CGPoint, current: CGPoint, ratio: CGFloat = ratio) -> CGRect {
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y

        var width = abs(dx)
        var height = abs(dy)
        if width / ratio >= height {
            height = width / ratio
        } else {
            width = height * ratio
        }

        return CGRect(
            x: dx < 0 ? anchor.x - width : anchor.x,
            y: dy < 0 ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
    }

    /// Builds a ratio-locked rect without crossing the screen edge. Scaling
    /// both dimensions together preserves the ratio when the pointer leaves
    /// the display.
    static func rect(
        anchor: CGPoint,
        current: CGPoint,
        in bounds: CGRect,
        ratio: CGFloat = ratio,
        minimumSize: CGFloat = 0
    ) -> CGRect {
        let raw = rect(anchor: anchor, current: current, ratio: ratio)
        let minimumHeight = max(minimumSize, minimumSize / ratio)
        var height = max(raw.height, minimumHeight)
        var width = height * ratio

        let availableWidth =
            current.x < anchor.x
            ? anchor.x - bounds.minX
            : bounds.maxX - anchor.x
        let availableHeight =
            current.y < anchor.y
            ? anchor.y - bounds.minY
            : bounds.maxY - anchor.y
        let scale = min(
            1,
            min(
                max(0, availableWidth) / max(width, 1),
                max(0, availableHeight) / max(height, 1)
            )
        )
        width *= scale
        height *= scale

        return CGRect(
            x: current.x < anchor.x ? anchor.x - width : anchor.x,
            y: current.y < anchor.y ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
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
        let effectiveHitSize = max(0, min(hitSize, rect.width / 3, rect.height / 3))
        guard rect.insetBy(dx: -effectiveHitSize, dy: -effectiveHitSize).contains(point) else { return nil }

        let nearLeft = abs(point.x - rect.minX) <= effectiveHitSize
        let nearRight = abs(point.x - rect.maxX) <= effectiveHitSize
        let nearBottom = abs(point.y - rect.minY) <= effectiveHitSize
        let nearTop = abs(point.y - rect.maxY) <= effectiveHitSize

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
        minimumSize: CGFloat,
        lockedRatio: CGFloat? = nil
    ) -> CGRect {
        if let lockedRatio, handle != .move {
            return ratioLockedAdjustment(
                rect: rect,
                handle: handle,
                delta: delta,
                bounds: bounds,
                minimumSize: minimumSize,
                ratio: lockedRatio
            )
        }

        if handle == .move {
            var result = rect.offsetBy(dx: delta.x, dy: delta.y).standardized
            result.size.width = min(max(minimumSize, result.width), bounds.width)
            result.size.height = min(max(minimumSize, result.height), bounds.height)
            result.origin.x = min(max(bounds.minX, result.minX), bounds.maxX - result.width)
            result.origin.y = min(max(bounds.minY, result.minY), bounds.maxY - result.height)
            return result
        }

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .bottomLeft:
            minX = max(bounds.minX, min(rect.minX + delta.x, max(bounds.minX, maxX - minimumSize)))
            minY = max(bounds.minY, min(rect.minY + delta.y, max(bounds.minY, maxY - minimumSize)))
        case .bottomRight:
            maxX = min(bounds.maxX, max(rect.maxX + delta.x, min(bounds.maxX, minX + minimumSize)))
            minY = max(bounds.minY, min(rect.minY + delta.y, max(bounds.minY, maxY - minimumSize)))
        case .topLeft:
            minX = max(bounds.minX, min(rect.minX + delta.x, max(bounds.minX, maxX - minimumSize)))
            maxY = min(bounds.maxY, max(rect.maxY + delta.y, min(bounds.maxY, minY + minimumSize)))
        case .topRight:
            maxX = min(bounds.maxX, max(rect.maxX + delta.x, min(bounds.maxX, minX + minimumSize)))
            maxY = min(bounds.maxY, max(rect.maxY + delta.y, min(bounds.maxY, minY + minimumSize)))
        case .move:
            break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func ratioLockedAdjustment(
        rect: CGRect,
        handle: Handle,
        delta: CGPoint,
        bounds: CGRect,
        minimumSize: CGFloat,
        ratio: CGFloat
    ) -> CGRect {
        let anchor: CGPoint
        let originalCorner: CGPoint
        switch handle {
        case .bottomLeft:
            anchor = CGPoint(x: rect.maxX, y: rect.maxY)
            originalCorner = CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight:
            anchor = CGPoint(x: rect.minX, y: rect.maxY)
            originalCorner = CGPoint(x: rect.maxX, y: rect.minY)
        case .topLeft:
            anchor = CGPoint(x: rect.maxX, y: rect.minY)
            originalCorner = CGPoint(x: rect.minX, y: rect.maxY)
        case .topRight:
            anchor = CGPoint(x: rect.minX, y: rect.minY)
            originalCorner = CGPoint(x: rect.maxX, y: rect.maxY)
        case .move:
            return rect
        }

        let minimumHeight = max(minimumSize, minimumSize / ratio)
        let minimumWidth = minimumHeight * ratio
        let rawCurrent = CGPoint(
            x: originalCorner.x + delta.x,
            y: originalCorner.y + delta.y
        )
        let current = CGPoint(
            x: constrainedCoordinate(
                desired: rawCurrent.x,
                anchor: anchor.x,
                original: originalCorner.x,
                minBound: bounds.minX,
                maxBound: bounds.maxX,
                minimumExtent: minimumWidth
            ),
            y: constrainedCoordinate(
                desired: rawCurrent.y,
                anchor: anchor.y,
                original: originalCorner.y,
                minBound: bounds.minY,
                maxBound: bounds.maxY,
                minimumExtent: minimumHeight
            )
        )

        return RegionAspectConstraint.rect(
            anchor: anchor,
            current: current,
            in: bounds,
            ratio: ratio,
            minimumSize: minimumSize
        )
    }

    private static func constrainedCoordinate(
        desired: CGFloat,
        anchor: CGFloat,
        original: CGFloat,
        minBound: CGFloat,
        maxBound: CGFloat,
        minimumExtent: CGFloat
    ) -> CGFloat {
        let lowSpace = max(0, anchor - minBound)
        let highSpace = max(0, maxBound - anchor)
        let originalLow = original < anchor
        let wantsLow = desired == anchor ? originalLow : desired < anchor
        let lowHasRoom = minimumExtent > 0 ? lowSpace >= minimumExtent : lowSpace > 0
        let highHasRoom = minimumExtent > 0 ? highSpace >= minimumExtent : highSpace > 0
        let fallbackStep = max(minimumExtent, 1)

        if wantsLow {
            if lowHasRoom {
                return desired < anchor ? desired : anchor - fallbackStep
            }
            if highSpace > lowSpace {
                return anchor + fallbackStep
            }
            return desired < anchor ? desired : anchor - fallbackStep
        } else {
            if highHasRoom {
                return desired > anchor ? desired : anchor + fallbackStep
            }
            if lowSpace > highSpace {
                return anchor - fallbackStep
            }
            return desired > anchor ? desired : anchor + fallbackStep
        }
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
    private(set) var windows: [RegionSelectionWindow] = []
    private var continuation: CheckedContinuation<RecordingRegion?, Never>?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Presents the selection overlays and resolves with the chosen region,
    /// or nil when the user cancels with Esc or the calling task is cancelled.
    func select() async -> RecordingRegion? {
        guard continuation == nil, !Task.isCancelled else { return nil }
        guard !NSScreen.screens.isEmpty else {
            logger.error("Cannot select region: no screens available")
            return nil
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                beginSelection(continuation: continuation)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.finish(with: nil)
            }
        }
    }

    private func beginSelection(continuation: CheckedContinuation<RecordingRegion?, Never>) {
        guard !Task.isCancelled else {
            continuation.resume(returning: nil)
            return
        }

        self.continuation = continuation
        installCancelMonitors()

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
            window.onSelectionStart = { [weak self, weak window] in
                guard let self, let activeWindow = window else { return }
                self.clearSiblingSelections(except: activeWindow)
            }
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
    }

    private func clearSiblingSelections(except activeWindow: RegionSelectionWindow) {
        for sibling in windows where sibling !== activeWindow {
            sibling.resetSelection()
        }
    }

    private func installCancelMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == KeyCode.escape {
                self?.finish(with: nil)
                return nil
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finish(with: nil)
            }
        }
    }

    private func removeCancelMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private func finish(with region: RecordingRegion?) {
        guard let continuation else { return }
        self.continuation = nil
        removeCancelMonitors()
        for window in windows {
            window.orderOut(nil)
            window.close()
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

    var onSelectionStart: (() -> Void)? {
        get { selectionView?.onSelectionStart }
        set { selectionView?.onSelectionStart = newValue }
    }

    private var selectionView: RegionSelectionView? {
        contentView as? RegionSelectionView
    }

    func resetSelection() {
        selectionView?.resetSelection()
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

        let view = RegionSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            backingScaleFactor: screen.backingScaleFactor
        )
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

    override func flagsChanged(with event: NSEvent) {
        selectionView?.handleFlagsChanged(event)
    }
}

final class RegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onSelectionStart: (() -> Void)?

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
    private var lastDragPoint: CGPoint?
    private var isRatioLocked = false
    private let backingScaleFactor: CGFloat
    private let hintLabel: NSTextField

    private enum Hint {
        static let draw = "Drag to select the area to record — hold ⇧ for 16:9, Esc to cancel"
        static let adjust = "Drag to adjust — hold ⇧ for 16:9, Return to record, Esc to cancel"
    }

    init(frame frameRect: NSRect, backingScaleFactor: CGFloat) {
        self.backingScaleFactor = backingScaleFactor
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
        backingScaleFactor = 1
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

    func resetSelection() {
        phase = .idle
        startPoint = nil
        currentRect = nil
        activeHandle = nil
        handleDragOrigin = nil
        rectAtHandleDragStart = nil
        lastDragPoint = nil
        isRatioLocked = false
        showHint(Hint.draw)
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isRatioLocked = false

        // A double-click inside a drawn selection is the fast path to record.
        if phase == .adjusting, event.clickCount >= 2, let rect = currentRect, rect.contains(point) {
            commit()
            return
        }

        // Grabbing the selection or one of its corners adjusts it; anywhere
        // else starts a fresh selection.
        if phase == .adjusting,
            let rect = currentRect,
            let handle = RegionAdjustment.handle(at: point, in: rect)
        {
            activeHandle = handle
            handleDragOrigin = point
            rectAtHandleDragStart = rect
            lastDragPoint = point
            return
        }

        onSelectionStart?()
        phase = .drawing
        startPoint = point
        lastDragPoint = point
        currentRect = nil
        activeHandle = nil
        hintLabel.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point
        applyDrag(to: point, shiftPressed: event.modifierFlags.contains(.shift))
    }

    override func flagsChanged(with event: NSEvent) {
        handleFlagsChanged(event)
    }

    func handleFlagsChanged(_ event: NSEvent) {
        guard let point = lastDragPoint else { return }
        if activeHandle != nil || (startPoint != nil && currentRect != nil) {
            applyDrag(to: point, shiftPressed: event.modifierFlags.contains(.shift))
        }
    }

    private func applyDrag(to point: CGPoint, shiftPressed: Bool) {
        let lockedRatio = shiftPressed ? RegionAspectConstraint.ratio : nil
        isRatioLocked = lockedRatio != nil && activeHandle != .move

        if let handle = activeHandle,
            let origin = handleDragOrigin,
            let rect = rectAtHandleDragStart
        {
            currentRect = RegionAdjustment.adjusted(
                rect: rect,
                handle: handle,
                delta: CGPoint(x: point.x - origin.x, y: point.y - origin.y),
                bounds: bounds,
                minimumSize: RegionMath.minimumSelectionSize,
                lockedRatio: lockedRatio
            )
            needsDisplay = true
            return
        }

        guard let startPoint else { return }
        if lockedRatio != nil {
            currentRect = RegionAspectConstraint.rect(
                anchor: startPoint,
                current: point,
                in: bounds
            )
        } else {
            currentRect = CGRect(
                x: min(startPoint.x, point.x),
                y: min(startPoint.y, point.y),
                width: abs(point.x - startPoint.x),
                height: abs(point.y - startPoint.y)
            ).intersection(bounds)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isRatioLocked = false
        lastDragPoint = nil

        if activeHandle != nil {
            activeHandle = nil
            handleDragOrigin = nil
            rectAtHandleDragStart = nil
            needsDisplay = true
            return
        }

        startPoint = nil

        guard let rect = currentRect,
            rect.width >= RegionMath.minimumSelectionSize,
            rect.height >= RegionMath.minimumSelectionSize
        else {
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
        guard let rect = currentRect,
            rect.width >= RegionMath.minimumSelectionSize,
            rect.height >= RegionMath.minimumSelectionSize
        else {
            return
        }
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
            CGPoint(x: rect.maxX, y: rect.maxY),
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
            .foregroundColor: NSColor.white,
        ]
        let settings = AppSettings.shared
        let dimensions = RegionSelectionLabel.text(
            for: rect,
            backingScaleFactor: backingScaleFactor,
            maxHeight: settings.videoResolution.maxHeight,
            codec: settings.videoCodec
        )
        let text = (isRatioLocked ? "\(dimensions)  \(RegionAspectConstraint.label)" : dimensions) as NSString
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
            window.frame != cocoaFrame
        else {
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
