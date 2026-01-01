import Carbon
import Cocoa

@MainActor
class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onToggleRecording: (() -> Void)?

    private init() {}

    func start() {
        guard eventTap == nil else { return }

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
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue

        Task { @MainActor in
            let settings = AppSettings.shared
            let hotkey = settings.recordingHotkey

            let relevantFlags = flags & (
                UInt64(CGEventFlags.maskCommand.rawValue) |
                UInt64(CGEventFlags.maskShift.rawValue) |
                UInt64(CGEventFlags.maskAlternate.rawValue) |
                UInt64(CGEventFlags.maskControl.rawValue)
            )

            let hotkeyFlags = UInt64(hotkey.modifiers) & (
                UInt64(CGEventFlags.maskCommand.rawValue) |
                UInt64(CGEventFlags.maskShift.rawValue) |
                UInt64(CGEventFlags.maskAlternate.rawValue) |
                UInt64(CGEventFlags.maskControl.rawValue)
            )

            if keyCode == hotkey.keyCode && relevantFlags == hotkeyFlags {
                self.onToggleRecording?()
            }
        }

        return Unmanaged.passRetained(event)
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
