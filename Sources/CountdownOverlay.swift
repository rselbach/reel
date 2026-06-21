import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "CountdownOverlay")

private enum CountdownConstants {
    static let barHeight: CGFloat = 80
}

enum CountdownLayout {
    static let sequence = [3, 2, 1]

    static func barFrame(referenceFrame: CGRect) -> CGRect {
        CGRect(
            x: referenceFrame.origin.x,
            y: referenceFrame.origin.y,
            width: referenceFrame.width,
            height: CountdownConstants.barHeight
        )
    }
}

@MainActor
class CountdownOverlay {
    private var window: CountdownWindow?
    private var label: NSTextField?
    private var cancelled = false

    func show(targetFrame: CGRect? = nil) async -> Bool {
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

        let barFrame = CountdownLayout.barFrame(referenceFrame: referenceFrame)
        
        let window = CountdownWindow(
            contentRect: barFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = NSColor.systemRed
        window.isOpaque = true
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onEscape = { [weak self] in
            self?.cancelled = true
        }
        
        let label = NSTextField(labelWithString: "3")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 48, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: barFrame.width, height: CountdownConstants.barHeight)
        label.autoresizingMask = [.width, .height]
        
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = window
        self.label = label
        
        for count in CountdownLayout.sequence {
            if cancelled { break }
            label.stringValue = "\(count)"
            guard await waitOneSecond() else {
                return false
            }
        }
        
        if cancelled {
            label.stringValue = "Cancelled"
            window.backgroundColor = NSColor.systemGray
            _ = await waitOneSecond()
        }
        
        window.orderOut(nil)
        self.window = nil
        self.label = nil
        
        return !cancelled
    }

    private func waitOneSecond() async -> Bool {
        do {
            try await Task.sleep(for: .seconds(1))
            return true
        } catch {
            logger.warning("Countdown sleep interrupted: \(error.localizedDescription)")
            return false
        }
    }
}

class CountdownWindow: NSWindow {
    var onEscape: (() -> Void)?
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}
