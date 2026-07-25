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

/// A globally registered shortcut. Carbon identifies hot keys by a numeric id
/// within a signature, so the raw values double as those ids and must stay
/// stable and distinct.
enum HotkeyAction: UInt32, CaseIterable {
    case toggleRecording = 1
}

/// Carbon event handler; must be a C function, so it trampolines back into
/// the manager. Hot key events arrive on the main thread via the event
/// dispatcher target, matching the manager's MainActor isolation.
private let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let kind = GetEventKind(event)
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        manager.handleHotKeyEvent(kind: kind, hotKeyID: hotKeyID)
    }
}

/// Registers global shortcuts with Carbon's RegisterEventHotKey, which —
/// unlike a CGEvent tap — needs no Accessibility permission and consumes the
/// key combination system-wide by design.
@MainActor
class HotkeyManager {
    static let shared = HotkeyManager()

    /// Fired once per press of a registered shortcut.
    var onTrigger: ((HotkeyAction) -> Void)?
    var onHotkeyDisabled: ((String) -> Void)?

    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var combos: [HotkeyAction: AppSettings.HotkeyCombo] = [:]
    private var eventHandler: EventHandlerRef?
    private var isStarted = false
    // Carbon delivers repeated kEventHotKeyPressed events while a key is held
    // (auto-repeat); only the first press before a release should fire.
    private var heldActions: Set<HotkeyAction> = []

    private static let signature: OSType = 0x5245_454C  // "REEL"

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installEventHandlerIfNeeded()

        combos[.toggleRecording] = AppSettings.shared.recordingHotkey
        for action in HotkeyAction.allCases {
            register(action)
        }
    }

    func stop() {
        for action in HotkeyAction.allCases {
            unregister(action)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        isStarted = false
    }

    /// Re-registers one shortcut after the user records a new combination.
    func updateHotkey(_ combo: AppSettings.HotkeyCombo, for action: HotkeyAction) {
        combos[action] = combo
        guard isStarted else { return }
        register(action)
    }

    func handleHotKeyEvent(kind: UInt32, hotKeyID: EventHotKeyID) -> OSStatus {
        guard hotKeyID.signature == Self.signature,
              let action = HotkeyAction(rawValue: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

        switch kind {
        case UInt32(kEventHotKeyPressed):
            guard !heldActions.contains(action) else { return noErr }
            heldActions.insert(action)
            onTrigger?(action)
            return noErr
        case UInt32(kEventHotKeyReleased):
            heldActions.remove(action)
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
            onHotkeyDisabled?("Failed to enable global hotkeys (error \(status)).")
        }
    }

    private func register(_ action: HotkeyAction) {
        unregister(action)

        guard let combo = combos[action] else { return }
        guard combo.isUsableGlobalShortcut else {
            logger.warning("Refusing to register unusable global shortcut for \(action.rawValue)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
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
            logger.error("RegisterEventHotKey failed for \(action.rawValue) (status: \(status))")
            onHotkeyDisabled?(
                "Failed to register the global shortcut \(combo.displayString). It may already be in use by another app."
            )
            return
        }

        hotKeyRefs[action] = ref
        heldActions.remove(action)
    }

    private func unregister(_ action: HotkeyAction) {
        guard let ref = hotKeyRefs.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(ref)
        heldActions.remove(action)
    }
}
