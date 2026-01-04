import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.reel", category: "CountdownOverlay")

@MainActor
class CountdownOverlay {
    private var window: CountdownWindow?
    private var label: NSTextField?
    private var cancelled = false

    /// Converts Quartz coordinates (origin top-left, Y down) to Cocoa coordinates (origin bottom-left, Y up)
    private func quartzToCocoa(_ frame: CGRect) -> NSRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            logger.warning("No primary screen found for coordinate conversion")
            return nil
        }
        return NSRect(
            x: frame.origin.x,
            y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    func show(targetFrame: CGRect? = nil) async -> Bool {
        cancelled = false

        let referenceFrame: NSRect
        if let targetFrame {
            guard let converted = quartzToCocoa(targetFrame) else {
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

        let barHeight: CGFloat = 80
        let barFrame = NSRect(
            x: referenceFrame.origin.x,
            y: referenceFrame.maxY - barHeight,
            width: referenceFrame.width,
            height: barHeight
        )
        
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
        label.frame = NSRect(x: 0, y: 0, width: barFrame.width, height: barHeight)
        label.autoresizingMask = [.width, .height]
        
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = window
        self.label = label
        
        for count in [3, 2, 1] {
            if cancelled { break }
            label.stringValue = "\(count)"
            try? await Task.sleep(for: .seconds(1))
        }
        
        if cancelled {
            label.stringValue = "Cancelled"
            window.backgroundColor = NSColor.systemGray
            try? await Task.sleep(for: .seconds(1))
        }
        
        window.orderOut(nil)
        self.window = nil
        self.label = nil
        
        return !cancelled
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
