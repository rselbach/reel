import Carbon
import Cocoa

@MainActor
class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onToggleRecording: (() -> Void)?

    // Cached hotkey for synchronous access from event tap callback (protected by hotkeyLock)
    private let hotkeyLock = NSLock()
    private nonisolated(unsafe) var cachedKeyCode: UInt16 = AppSettings.HotkeyCombo.default.keyCode
    private nonisolated(unsafe) var cachedModifiers: UInt32 = AppSettings.HotkeyCombo.default.modifiers

    private init() {}

    func updateCachedHotkey(_ combo: AppSettings.HotkeyCombo) {
        hotkeyLock.lock()
        cachedKeyCode = combo.keyCode
        cachedModifiers = combo.modifiers
        hotkeyLock.unlock()
    }

    func start() {
        guard eventTap == nil else { return }

        // Initialize cached hotkey from current settings
        let hotkey = AppSettings.shared.recordingHotkey
        updateCachedHotkey(hotkey)

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        )

        guard let eventTap else {
            print("Failed to create event tap. Check accessibility permissions.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    private nonisolated func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = UInt32(event.flags.rawValue) & AppSettings.HotkeyCombo.modifierMask

        // Check synchronously using cached hotkey values
        hotkeyLock.lock()
        let expectedKeyCode = cachedKeyCode
        let expectedModifiers = cachedModifiers
        hotkeyLock.unlock()

        if keyCode == expectedKeyCode && flags == expectedModifiers {
            // Consume the event and trigger the callback
            Task { @MainActor in
                self.onToggleRecording?()
            }
            return nil  // Consume the event so it doesn't reach other apps
        }

        return Unmanaged.passUnretained(event)
    }

    func hasAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
