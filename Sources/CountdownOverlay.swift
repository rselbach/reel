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

    /// The HUD never takes key focus, so Esc cannot reach it. Clicking it and
    /// pressing the recording shortcut again are the two ways out.
    static func cancelHint(shortcut: String) -> String {
        "Click or press \(shortcut) to cancel"
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
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // Reel is an accessory app and is rarely the active one; without this
        // the panel would vanish the moment focus returns to the demo target.
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = CountdownContentView(frame: NSRect(origin: .zero, size: hudFrame.size))
        content.onClick = { [weak self] in
            self?.cancelled = true
        }
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

        let hint = NSTextField(
            labelWithString: CountdownLayout.cancelHint(
                shortcut: AppSettings.shared.recordingHotkey.displayString
            )
        )
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.7)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 16, width: CountdownLayout.hudSize, height: 16)
        hint.autoresizingMask = [.width]
        content.addSubview(hint)

        // Deliberately not makeKeyAndOrderFront/activate: the whole point of
        // the countdown is to give the user time to leave the app they are
        // about to demo in front. Taking key or activating Reel here means
        // recording starts with the wrong window focused.
        window.orderFrontRegardless()

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

/// Non-activating panel: it floats above everything without making Reel the
/// active app, so the window the user is about to record keeps its focus.
class CountdownWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the very first click even though the panel never becomes key, so a
/// single click on the HUD cancels instead of merely focusing it.
final class CountdownContentView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
