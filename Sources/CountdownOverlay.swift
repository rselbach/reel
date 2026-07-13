import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "CountdownOverlay")

enum CountdownLayout {
    static let hudSize: CGFloat = 160

    static func sequence(duration: Int) -> [Int] {
        guard duration > 0 else { return [] }
        return Array((1...duration).reversed())
    }

    /// Small HUD centered over the area about to be recorded.
    static func hudFrame(referenceFrame: CGRect) -> CGRect {
        CGRect(
            x: referenceFrame.midX - hudSize / 2,
            y: referenceFrame.midY - hudSize / 2,
            width: hudSize,
            height: hudSize
        )
    }
}

@MainActor
class CountdownOverlay {
    private var window: CountdownWindow?
    private var label: NSTextField?
    private var cancelled = false

    /// Cancels a countdown in progress (e.g. the hotkey was pressed again).
    func cancel() {
        cancelled = true
    }

    /// Shows the countdown and returns true when recording should start.
    /// A duration of 0 means the countdown is disabled and recording starts
    /// immediately. Cancellable by clicking the HUD, pressing Esc, or calling
    /// cancel().
    func show(targetFrame: CGRect? = nil, duration: Int) async -> Bool {
        guard duration > 0 else { return true }
        cancelled = false

        let referenceFrame: NSRect
        if let targetFrame {
            guard let converted = cocoaRect(fromQuartz: targetFrame) else {
                logger.error("Cannot show countdown: no screens available for coordinate conversion")
                return false
            }
            referenceFrame = converted
        } else if let screen = NSScreen.main {
            referenceFrame = screen.frame
        } else {
            logger.error("Cannot show countdown: no target frame and no main screen available")
            return false
        }

        let hudFrame = CountdownLayout.hudFrame(referenceFrame: referenceFrame)

        let window = CountdownWindow(
            contentRect: hudFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onCancel = { [weak self] in
            self?.cancelled = true
        }

        let content = NSView(frame: NSRect(origin: .zero, size: hudFrame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        content.layer?.cornerRadius = 28
        window.contentView = content

        let label = NSTextField(labelWithString: "\(duration)")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 40, width: CountdownLayout.hudSize, height: 90)
        label.autoresizingMask = [.width]
        content.addSubview(label)

        let hint = NSTextField(labelWithString: "Click or Esc to cancel")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.7)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 16, width: CountdownLayout.hudSize, height: 16)
        hint.autoresizingMask = [.width]
        content.addSubview(hint)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.label = label

        defer {
            window.orderOut(nil)
            self.window = nil
            self.label = nil
        }

        var interrupted = false
        countdown: for count in CountdownLayout.sequence(duration: duration) {
            if cancelled { break }
            label.stringValue = "\(count)"
            // Sleep in short slices so cancellation reacts promptly.
            for _ in 0..<10 {
                if cancelled { break countdown }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    logger.warning("Countdown sleep interrupted: \(error.localizedDescription)")
                    interrupted = true
                    break countdown
                }
            }
        }

        if cancelled {
            label.stringValue = "✕"
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                logger.warning("Countdown cancel display interrupted: \(error.localizedDescription)")
            }
        }

        return !cancelled && !interrupted
    }
}

class CountdownWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onCancel?()
    }
}
