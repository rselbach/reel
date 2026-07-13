import AppKit
import Carbon
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "HotkeyManager")

enum CarbonModifierTranslation {
    /// Converts the NSEvent/CGEvent device-independent modifier mask stored in
    /// HotkeyCombo into the Carbon modifier mask RegisterEventHotKey expects.
    static func carbonModifiers(fromEventModifiers modifiers: UInt32) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers & 0x40000 != 0 { carbon |= UInt32(controlKey) }
        if modifiers & 0x80000 != 0 { carbon |= UInt32(optionKey) }
        if modifiers & 0x20000 != 0 { carbon |= UInt32(shiftKey) }
        if modifiers & 0x100000 != 0 { carbon |= UInt32(cmdKey) }
        return carbon
    }
}

/// Carbon event handler; must be a C function, so it trampolines back into
/// the manager. Hot key events arrive on the main thread via the event
/// dispatcher target, matching the manager's MainActor isolation.
private let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let kind = GetEventKind(event)
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        manager.handleHotKeyEvent(kind: kind)
    }
}

/// Registers the global recording shortcut with Carbon's RegisterEventHotKey,
/// which — unlike a CGEvent tap — needs no Accessibility permission and
/// consumes the key combination system-wide by design.
@MainActor
class HotkeyManager {
    static let shared = HotkeyManager()

    var onToggleRecording: (() -> Void)?
    var onHotkeyDisabled: ((String) -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isStarted = false
    // Carbon delivers repeated kEventHotKeyPressed events while the key is
    // held (auto-repeat); only the first press before a release should toggle.
    private var isHotkeyHeld = false

    private static let signature: OSType = 0x5245_454C  // "REEL"

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installEventHandlerIfNeeded()
        registerCurrentHotkey()
    }

    func stop() {
        unregisterHotkey()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        isStarted = false
    }

    /// Re-registers the shortcut after the user records a new combination.
    func updateHotkey(_ combo: AppSettings.HotkeyCombo) {
        guard isStarted else { return }
        registerCurrentHotkey()
    }

    func handleHotKeyEvent(kind: UInt32) -> OSStatus {
        switch kind {
        case UInt32(kEventHotKeyPressed):
            guard !isHotkeyHeld else { return noErr }
            isHotkeyHeld = true
            onToggleRecording?()
            return noErr
        case UInt32(kEventHotKeyReleased):
            isHotkeyHeld = false
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyEventHandler,
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &eventHandler
        )
        if status != noErr {
            logger.error("InstallEventHandler failed (status: \(status))")
            onHotkeyDisabled?("Failed to enable the global hotkey (error \(status)).")
        }
    }

    private func registerCurrentHotkey() {
        unregisterHotkey()

        let combo = AppSettings.shared.recordingHotkey
        guard combo.isUsableGlobalShortcut else {
            logger.warning("Refusing to register unusable global shortcut")
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            CarbonModifierTranslation.carbonModifiers(fromEventModifiers: combo.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            logger.error("RegisterEventHotKey failed (status: \(status))")
            onHotkeyDisabled?(
                "Failed to register the global shortcut \(combo.displayString). It may already be in use by another app."
            )
            return
        }

        hotKeyRef = ref
        isHotkeyHeld = false
    }

    private func unregisterHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
