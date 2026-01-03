import AppKit

@MainActor
class CountdownOverlay {
    private var window: CountdownWindow?
    private var label: NSTextField?
    private var cancelled = false
    
    func show() async -> Bool {
        cancelled = false
        guard let screen = NSScreen.main else { return false }
        
        let barHeight: CGFloat = 80
        let barFrame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.maxY - barHeight,
            width: screen.frame.width,
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
