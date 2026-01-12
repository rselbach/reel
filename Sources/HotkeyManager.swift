import Carbon
import Cocoa
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "HotkeyManager")

@MainActor
class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onToggleRecording: (() -> Void)?
    var onHotkeyDisabled: ((String) -> Void)?

    // Cached state for synchronous access from event tap callback (protected by hotkeyLock)
    private let hotkeyLock = NSLock()
    private nonisolated(unsafe) var cachedKeyCode: UInt16 = AppSettings.HotkeyCombo.default.keyCode
    private nonisolated(unsafe) var cachedModifiers: UInt32 = AppSettings.HotkeyCombo.default.modifiers
    private nonisolated(unsafe) var cachedEventTap: CFMachPort?
    private nonisolated(unsafe) var cachedHotkeyDisabledHandler: ((String) -> Void)?

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
            guard let refcon else { return Unmanaged.passUnretained(event) }
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
            logger.error("Failed to create event tap. Check accessibility permissions.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        hotkeyLock.lock()
        cachedEventTap = eventTap
        cachedHotkeyDisabledHandler = onHotkeyDisabled
        hotkeyLock.unlock()
    }

    func stop() {
        hotkeyLock.lock()
        cachedEventTap = nil
        hotkeyLock.unlock()

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
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            logger.warning("Event tap disabled by \(reason), re-enabling")

            hotkeyLock.lock()
            let tap = cachedEventTap
            let onHotkeyDisabled = cachedHotkeyDisabledHandler
            hotkeyLock.unlock()

            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                logger.error("Cannot re-enable event tap: tap is nil")
                Task { @MainActor in
                    onHotkeyDisabled?("Hotkey stopped working and could not be restored. Please restart the app.")
                }
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            break
        default:
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
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
