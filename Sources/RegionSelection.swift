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
        if event.keyCode == KeyCode.escape {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class RegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: CGRect?
    private let hintLabel: NSTextField

    override init(frame frameRect: NSRect) {
        hintLabel = NSTextField(labelWithString: "Drag to select the area to record — Esc to cancel")
        super.init(frame: frameRect)

        hintLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        hintLabel.drawsBackground = true
        hintLabel.alignment = .center
        hintLabel.sizeToFit()
        let padded = NSRect(
            x: (frameRect.width - hintLabel.frame.width - 24) / 2,
            y: frameRect.height - 80,
            width: hintLabel.frame.width + 24,
            height: hintLabel.frame.height + 12
        )
        hintLabel.frame = padded
        hintLabel.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        addSubview(hintLabel)
    }

    required init?(coder: NSCoder) {
        hintLabel = NSTextField(labelWithString: "")
        super.init(coder: coder)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        hintLabel.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(point.x - startPoint.x),
            height: abs(point.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            currentRect = nil
        }
        guard let rect = currentRect,
              rect.width >= RegionMath.minimumSelectionSize,
              rect.height >= RegionMath.minimumSelectionSize else {
            // Stray click or tiny drag: keep waiting for a real selection.
            hintLabel.isHidden = false
            needsDisplay = true
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

        drawSizeReadout(for: rect)
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
