import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import os.log
import ServiceManagement

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "Settings")

enum SettingsErrorText {
    static let launchAtLoginUpdateFailed = "Failed to update launch at login"
}

enum HotkeyConflictText {
    static func message(shortcut: String, otherAction: String) -> String {
        "\(shortcut) is already used by \(otherAction.replacingOccurrences(of: ":", with: "").lowercased())."
    }
}

enum RecentRecordingsLogic {
    /// Most-recent-first, deduplicated, capped at limit.
    static func updatedPaths(current: [String], adding path: String, limit: Int) -> [String] {
        var paths = current.filter { $0 != path }
        paths.insert(path, at: 0)
        return Array(paths.prefix(limit))
    }

    static func removingPath(_ path: String, from current: [String]) -> [String] {
        current.filter { $0 != path }
    }
}

/// The recording target remembered between launches.
///
/// Windows are identified by owning application and title rather than by
/// CGWindowID, which is only meaningful while that particular window exists.
enum RememberedTarget: Codable, Equatable {
    case display(CGDirectDisplayID)
    case window(bundleID: String, title: String?)
    case region(displayID: CGDirectDisplayID, x: Double, y: Double, width: Double, height: Double)
}

enum RememberedTargetMatching {
    /// Restores a remembered window only when its app and title identify one
    /// current window unambiguously. Falling back to another window from the
    /// same app could silently record unrelated or private content.
    static func bestMatchIndex(
        bundleIDs: [String?],
        titles: [String?],
        wantedBundleID: String,
        wantedTitle: String?
    ) -> Int? {
        let matches = bundleIDs.indices.filter {
            bundleIDs[$0] == wantedBundleID &&
                titles.indices.contains($0) &&
                titles[$0] == wantedTitle
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// String-backed setting whose rawValue is a stable storage key, decoupled
/// from the label shown in the UI so rewording a label never resets stored
/// preferences.
protocol StoredAppSetting: RawRepresentable, CaseIterable where RawValue == String {
    var displayName: String { get }
}

extension StoredAppSetting {
    /// Decodes a persisted value, accepting both the stable rawValue and the
    /// display label because older builds persisted the labels themselves.
    static func fromStored(_ stored: String?) -> Self? {
        guard let stored else { return nil }
        return Self(rawValue: stored) ?? Self.allCases.first { $0.displayName == stored }
    }
}

// MARK: - Key Codes (Carbon virtual key codes)
enum KeyCode {
    static let escape: UInt16 = 53
    static let `return`: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117

    // Letters
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let f: UInt16 = 3
    static let h: UInt16 = 4
    static let g: UInt16 = 5
    static let z: UInt16 = 6
    static let x: UInt16 = 7
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let b: UInt16 = 11
    static let q: UInt16 = 12
    static let w: UInt16 = 13
    static let e: UInt16 = 14
    static let r: UInt16 = 15
    static let y: UInt16 = 16
    static let t: UInt16 = 17
    static let o: UInt16 = 31
    static let u: UInt16 = 32
    static let i: UInt16 = 34
    static let p: UInt16 = 35
    static let l: UInt16 = 37
    static let j: UInt16 = 38
    static let k: UInt16 = 40
    static let n: UInt16 = 45
    static let m: UInt16 = 46

    // Numbers
    static let zero: UInt16 = 29
    static let one: UInt16 = 18
    static let two: UInt16 = 19
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let five: UInt16 = 23
    static let six: UInt16 = 22
    static let seven: UInt16 = 26
    static let eight: UInt16 = 28
    static let nine: UInt16 = 25

    // Function keys
    static let f1: UInt16 = 122
    static let f2: UInt16 = 120
    static let f3: UInt16 = 99
    static let f4: UInt16 = 118
    static let f5: UInt16 = 96
    static let f6: UInt16 = 97
    static let f7: UInt16 = 98
    static let f8: UInt16 = 100
    static let f9: UInt16 = 101
    static let f10: UInt16 = 109
    static let f11: UInt16 = 103
    static let f12: UInt16 = 111
}

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private var isSyncingLaunchAtLogin = false

    private enum DefaultsKey {
        static let launchAtLogin = "launchAtLogin"
        static let hasShownWelcome = "hasShownWelcome"
        static let showCursor = "showCursor"
        static let highlightClicks = "highlightClicks"
        static let frameWindowRecordings = "frameWindowRecordings"
        static let windowBackground = "windowBackground"
        static let frameRate = "frameRate"
        static let videoQuality = "videoQuality"
        static let videoResolution = "videoResolution"
        static let videoCodec = "videoCodec"
        static let outputDirectory = "outputDirectory"
        static let askWhereToSave = "askWhereToSave"
        static let openFinderAfterRecording = "openFinderAfterRecording"
        static let showPreviewAfterRecording = "showPreviewAfterRecording"
        static let recordingHotkey = "recordingHotkey"
        static let discardHotkey = "discardHotkey"
        static let pauseHotkey = "pauseHotkey"
        static let countdownDuration = "countdownDuration"
        static let recordAudio = "recordAudio"
        static let audioSource = "audioSource"
        static let audioDeviceID = "audioDeviceID"
        static let recordCamera = "recordCamera"
        static let cameraDeviceID = "cameraDeviceID"
        static let cameraPosition = "cameraPosition"
        static let cameraSize = "cameraSize"
        static let cameraSizeFraction = "cameraSizeFraction"
        static let cameraShape = "cameraShape"
        static let textOverlayEnabled = "textOverlayEnabled"
        static let textOverlayText = "textOverlayText"
        static let textOverlayPosition = "textOverlayPosition"
        static let recentRecordings = "recentRecordings"
        static let playSoundCues = "playSoundCues"
        static let rememberedTarget = "rememberedTarget"
    }

    private func persist(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func defaultOutputDirectory() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private static func isWritableDirectory(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path()) {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path(), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return false
            }
            return FileManager.default.isWritableFile(atPath: url.path())
        }

        let parent = url.deletingLastPathComponent()
        guard parent.path != "/" && parent.path != url.path else {
            return false
        }
        return FileManager.default.fileExists(atPath: parent.path()) &&
            FileManager.default.isWritableFile(atPath: parent.path())
    }

    @Published var launchAtLogin: Bool {
        didSet {
            persist(launchAtLogin, key: DefaultsKey.launchAtLogin)
            if !isSyncingLaunchAtLogin {
                updateLaunchAtLogin()
            }
        }
    }

    @Published var launchAtLoginError: String?

    @Published var hasShownWelcome: Bool {
        didSet { persist(hasShownWelcome, key: DefaultsKey.hasShownWelcome) }
    }

    @Published var showCursor: Bool {
        didSet { persist(showCursor, key: DefaultsKey.showCursor) }
    }

    /// Marks where the pointer is pressed, so viewers can see clicks and
    /// drags that the cursor alone does not convey.
    @Published var highlightClicks: Bool {
        didSet { persist(highlightClicks, key: DefaultsKey.highlightClicks) }
    }

    /// Draws window recordings inset on a background with rounded corners and
    /// a shadow, rather than as a bare rectangle of window pixels.
    @Published var frameWindowRecordings: Bool {
        didSet { persist(frameWindowRecordings, key: DefaultsKey.frameWindowRecordings) }
    }

    @Published var windowBackground: WindowBackground {
        didSet { persist(windowBackground.rawValue, key: DefaultsKey.windowBackground) }
    }

    @Published var frameRate: Int {
        didSet {
            let sanitized = Self.sanitizedFrameRate(frameRate)
            if sanitized != frameRate {
                frameRate = sanitized
                return
            }
            persist(frameRate, key: DefaultsKey.frameRate)
        }
    }

    @Published var videoQuality: VideoQuality {
        didSet { persist(videoQuality.rawValue, key: DefaultsKey.videoQuality) }
    }

    @Published var videoResolution: VideoResolution {
        didSet { persist(videoResolution.rawValue, key: DefaultsKey.videoResolution) }
    }

    @Published var videoCodec: VideoCodec {
        didSet { persist(videoCodec.rawValue, key: DefaultsKey.videoCodec) }
    }

    @Published var outputDirectory: URL {
        didSet {
            persist(outputDirectory.path(), key: DefaultsKey.outputDirectory)
        }
    }

    @Published var askWhereToSave: Bool {
        didSet { persist(askWhereToSave, key: DefaultsKey.askWhereToSave) }
    }

    @Published var openFinderAfterRecording: Bool {
        didSet { persist(openFinderAfterRecording, key: DefaultsKey.openFinderAfterRecording) }
    }

    @Published var showPreviewAfterRecording: Bool {
        didSet { persist(showPreviewAfterRecording, key: DefaultsKey.showPreviewAfterRecording) }
    }

    /// Start and stop cues are played through the speakers, so anyone
    /// recording narration over a live microphone will want them off.
    @Published var playSoundCues: Bool {
        didSet { persist(playSoundCues, key: DefaultsKey.playSoundCues) }
    }

    static let hotkeyChangedNotification = Notification.Name("AppSettingsHotkeyChanged")

    @Published var recordingHotkey: HotkeyCombo {
        didSet {
            persistHotkey(recordingHotkey, key: DefaultsKey.recordingHotkey, action: .toggleRecording)
        }
    }

    /// Ends a take and throws the file away, for a flubbed demo.
    @Published var discardHotkey: HotkeyCombo {
        didSet {
            persistHotkey(discardHotkey, key: DefaultsKey.discardHotkey, action: .discardRecording)
        }
    }

    /// Pauses or resumes without ending the take.
    @Published var pauseHotkey: HotkeyCombo {
        didSet {
            persistHotkey(pauseHotkey, key: DefaultsKey.pauseHotkey, action: .pauseRecording)
        }
    }

    /// Non-nil when the user tried to assign a shortcut another action already
    /// owns. Carbon would simply refuse the second registration, leaving one
    /// shortcut silently dead.
    @Published var hotkeyConflictError: String?

    func hotkey(for action: HotkeyAction) -> HotkeyCombo {
        switch action {
        case .toggleRecording: return recordingHotkey
        case .discardRecording: return discardHotkey
        case .pauseRecording: return pauseHotkey
        }
    }

    /// Assigns a shortcut, refusing combinations already taken by another
    /// action rather than letting the second registration fail silently.
    func setHotkey(_ combo: HotkeyCombo, for action: HotkeyAction) {
        if let conflict = HotkeyAction.allCases.first(where: { $0 != action && hotkey(for: $0) == combo }) {
            hotkeyConflictError = HotkeyConflictText.message(
                shortcut: combo.displayString,
                otherAction: conflict.displayName
            )
            return
        }

        hotkeyConflictError = nil
        switch action {
        case .toggleRecording: recordingHotkey = combo
        case .discardRecording: discardHotkey = combo
        case .pauseRecording: pauseHotkey = combo
        }
    }

    private func persistHotkey(_ combo: HotkeyCombo, key: String, action: HotkeyAction) {
        do {
            let data = try JSONEncoder().encode(combo)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            logger.warning("Failed to persist \(key): \(error.localizedDescription)")
        }
        HotkeyManager.shared.updateHotkey(combo, for: action)
        NotificationCenter.default.post(name: Self.hotkeyChangedNotification, object: nil)
    }

    @Published var countdownDuration: Int {
        didSet {
            let sanitized = Self.sanitizedCountdownDuration(countdownDuration)
            if sanitized != countdownDuration {
                countdownDuration = sanitized
                return
            }
            persist(countdownDuration, key: DefaultsKey.countdownDuration)
        }
    }

    @Published var recordAudio: Bool {
        didSet { persist(recordAudio, key: DefaultsKey.recordAudio) }
    }

    @Published var audioSource: AudioSource {
        didSet { persist(audioSource.rawValue, key: DefaultsKey.audioSource) }
    }

    @Published var audioDeviceID: String? {
        didSet { persist(audioDeviceID, key: DefaultsKey.audioDeviceID) }
    }

    @Published var recordCamera: Bool {
        didSet { persist(recordCamera, key: DefaultsKey.recordCamera) }
    }

    @Published var cameraDeviceID: String? {
        didSet { persist(cameraDeviceID, key: DefaultsKey.cameraDeviceID) }
    }

    @Published var cameraPosition: CameraOverlayPosition {
        didSet { persist(cameraPosition.rawValue, key: DefaultsKey.cameraPosition) }
    }

    /// Camera overlay width as a fraction of the recording width. The single
    /// source of truth for overlay size: the Small/Medium/Large picker writes
    /// preset values here, and live corner-drag resizes persist here too.
    @Published var cameraSizeFraction: CGFloat {
        didSet {
            let sanitized = Self.sanitizedCameraSizeFraction(cameraSizeFraction)
            if sanitized != cameraSizeFraction {
                cameraSizeFraction = sanitized
                return
            }
            persist(Double(cameraSizeFraction), key: DefaultsKey.cameraSizeFraction)
        }
    }

    static func sanitizedCameraSizeFraction(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, CameraOverlayResizeLogic.minFraction), CameraOverlayResizeLogic.maxFraction)
    }

    /// The preset matching the current fraction, or nil for a custom size
    /// reached by dragging the overlay's corners.
    var cameraSizePreset: CameraOverlaySize? {
        CameraOverlaySize.allCases.first { abs($0.fraction - cameraSizeFraction) < 0.001 }
    }

    @Published var cameraShape: CameraOverlayShape {
        didSet { persist(cameraShape.rawValue, key: DefaultsKey.cameraShape) }
    }

    @Published var textOverlayEnabled: Bool {
        didSet { persist(textOverlayEnabled, key: DefaultsKey.textOverlayEnabled) }
    }

    @Published var textOverlayText: String {
        didSet { persist(textOverlayText, key: DefaultsKey.textOverlayText) }
    }

    @Published var textOverlayPosition: TextOverlayPosition {
        didSet { persist(textOverlayPosition.rawValue, key: DefaultsKey.textOverlayPosition) }
    }

    /// What the last recording captured, so a relaunch does not silently fall
    /// back to the primary display.
    @Published var rememberedTarget: RememberedTarget? {
        didSet {
            guard let rememberedTarget else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.rememberedTarget)
                return
            }
            do {
                let data = try JSONEncoder().encode(rememberedTarget)
                UserDefaults.standard.set(data, forKey: DefaultsKey.rememberedTarget)
            } catch {
                logger.warning("Failed to persist remembered recording target: \(error.localizedDescription)")
            }
        }
    }

    private static func loadRememberedTarget(from defaults: UserDefaults) -> RememberedTarget? {
        guard let data = defaults.data(forKey: DefaultsKey.rememberedTarget) else { return nil }
        do {
            return try JSONDecoder().decode(RememberedTarget.self, from: data)
        } catch {
            logger.warning("Failed to decode remembered recording target: \(error.localizedDescription)")
            return nil
        }
    }

    static let maxRecentRecordings = 5

    @Published var recentRecordingPaths: [String] {
        didSet { persist(recentRecordingPaths, key: DefaultsKey.recentRecordings) }
    }

    func noteRecentRecording(_ url: URL) {
        recentRecordingPaths = RecentRecordingsLogic.updatedPaths(
            current: recentRecordingPaths,
            adding: url.path(),
            limit: Self.maxRecentRecordings
        )
    }

    func forgetRecentRecording(_ url: URL) {
        recentRecordingPaths = RecentRecordingsLogic.removingPath(
            url.path(),
            from: recentRecordingPaths
        )
    }

    /// Recent recordings that still exist on disk.
    var existingRecentRecordings: [URL] {
        recentRecordingPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path()) }
    }

    enum AudioSource: String, StoredAppSetting {
        case microphone
        case systemAudio

        var displayName: String {
            switch self {
            case .microphone: return "Microphone"
            case .systemAudio: return "System Audio"
            }
        }
    }

    enum CameraOverlayPosition: String, StoredAppSetting {
        case bottomLeft
        case bottomRight
        case topLeft
        case topRight

        var displayName: String {
            switch self {
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            }
        }

        /// Returns normalized (x, y) coordinates for this corner position.
        /// X: 0.0 = left, 1.0 = right
        /// Y: 0.0 = bottom, 1.0 = top (Core Image coordinate system)
        var normalizedCoordinates: (x: CGFloat, y: CGFloat) {
            switch self {
            case .bottomLeft:  return (0.0, 0.0)
            case .bottomRight: return (1.0, 0.0)
            case .topLeft:     return (0.0, 1.0)
            case .topRight:    return (1.0, 1.0)
            }
        }
    }

    enum CameraOverlaySize: String, StoredAppSetting {
        case small
        case medium
        case large

        var displayName: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }

        var fraction: CGFloat {
            switch self {
            case .small: return 0.15
            case .medium: return 0.2
            case .large: return 0.25
            }
        }
    }

    enum CameraOverlayShape: String, StoredAppSetting {
        case rectangle
        case circle

        var displayName: String {
            switch self {
            case .rectangle: return "Rectangle"
            case .circle: return "Circle"
            }
        }
    }

    enum TextOverlayPosition: String, StoredAppSetting {
        case top
        case center
        case bottom

        var displayName: String {
            switch self {
            case .top: return "Top"
            case .center: return "Center"
            case .bottom: return "Bottom"
            }
        }
    }

    var activeTextOverlayText: String? {
        guard textOverlayEnabled else { return nil }
        let text = textOverlayText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var availableAudioDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    var selectedAudioDevice: AVCaptureDevice? {
        guard let id = audioDeviceID else {
            return AVCaptureDevice.default(for: .audio)
        }
        return availableAudioDevices.first { $0.uniqueID == id }
            ?? AVCaptureDevice.default(for: .audio)
    }

    var availableCameras: [AVCaptureDevice] {
        // Deployment target is macOS 26, so .deskViewCamera (macOS 13) and
        // .continuityCamera (macOS 14) are always available.
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .deskViewCamera, .continuityCamera]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    var selectedCamera: AVCaptureDevice? {
        guard let id = cameraDeviceID else {
            return AVCaptureDevice.default(for: .video)
        }
        return availableCameras.first { $0.uniqueID == id }
            ?? AVCaptureDevice.default(for: .video)
    }

    enum WindowBackground: String, StoredAppSetting {
        case charcoal
        case slate
        case linen
        case dusk
        case mist

        var displayName: String {
            switch self {
            case .charcoal: return "Charcoal"
            case .slate: return "Slate"
            case .linen: return "Linen"
            case .dusk: return "Dusk (gradient)"
            case .mist: return "Mist (gradient)"
            }
        }

        var fill: FrameCompositor.BackgroundFill {
            switch self {
            case .charcoal:
                return .solid(CIColor(red: 0.11, green: 0.11, blue: 0.13))
            case .slate:
                return .solid(CIColor(red: 0.20, green: 0.25, blue: 0.33))
            case .linen:
                return .solid(CIColor(red: 0.93, green: 0.91, blue: 0.87))
            case .dusk:
                return .linearGradient(
                    from: CIColor(red: 0.13, green: 0.11, blue: 0.28),
                    to: CIColor(red: 0.45, green: 0.24, blue: 0.44)
                )
            case .mist:
                return .linearGradient(
                    from: CIColor(red: 0.85, green: 0.89, blue: 0.93),
                    to: CIColor(red: 0.68, green: 0.75, blue: 0.84)
                )
            }
        }
    }

    enum VideoCodec: String, StoredAppSetting {
        case h264
        case hevc

        var displayName: String {
            switch self {
            case .h264: return "H.264 (most compatible)"
            case .hevc: return "HEVC (smaller files)"
            }
        }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            }
        }

        /// Only H.264 gets an explicit profile level; HEVC is left to pick its
        /// own, since the H.264 constant is not a valid value for it.
        var profileLevel: String? {
            switch self {
            case .h264: return AVVideoProfileLevelH264HighAutoLevel
            case .hevc: return nil
            }
        }

        /// Conservative dimension ceiling for broad AVAssetWriter
        /// compatibility. HEVC handles considerably larger frames than H.264.
        var maxDimensions: CGSize {
            switch self {
            case .h264: return CGSize(width: 4096, height: 2304)
            case .hevc: return CGSize(width: 8192, height: 4320)
            }
        }
    }

    /// Caps the recorded height. A Retina display captured natively produces
    /// an unusually large, oddly sized file; most demos are shown at 1080p or
    /// less, and the smaller frame is cheaper to encode as well.
    enum VideoResolution: String, StoredAppSetting {
        case native
        case p720
        case p1080
        case p1440

        var displayName: String {
            switch self {
            case .native: return "Native (full detail)"
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p1440: return "1440p"
            }
        }

        /// Maximum output height in pixels, or nil to keep the source size.
        var maxHeight: CGFloat? {
            switch self {
            case .native: return nil
            case .p720: return 720
            case .p1080: return 1080
            case .p1440: return 1440
            }
        }
    }

    enum VideoQuality: String, StoredAppSetting {
        case low
        case medium
        case high
        case maximum

        var displayName: String {
            switch self {
            case .low: return "Low (5 Mbps)"
            case .medium: return "Medium (10 Mbps)"
            case .high: return "High (20 Mbps)"
            case .maximum: return "Maximum (50 Mbps)"
            }
        }

        var bitrate: Int {
            switch self {
            case .low: return 5_000_000
            case .medium: return 10_000_000
            case .high: return 20_000_000
            case .maximum: return 50_000_000
            }
        }
    }

    static let supportedFrameRates = [30, 60]

    /// 0 disables the countdown entirely.
    static let supportedCountdownDurations = [0, 3, 5, 10]

    static func sanitizedCountdownDuration(_ duration: Int) -> Int {
        supportedCountdownDurations.contains(duration) ? duration : 3
    }

    static let defaultFrameRate = 30

    static func sanitizedFrameRate(_ frameRate: Int) -> Int {
        guard frameRate > 0 else { return defaultFrameRate }
        if supportedFrameRates.contains(frameRate) { return frameRate }

        let closest = supportedFrameRates.min(by: { abs($0 - frameRate) < abs($1 - frameRate) }) ?? defaultFrameRate
        return closest
    }

    struct HotkeyCombo: Codable, Equatable {
        var keyCode: UInt16
        var modifiers: UInt32

        // Device-independent modifier mask (works for both NSEvent and CGEvent)
        static let modifierMask: UInt32 = 0x1E0000  // Cmd|Opt|Ctrl|Shift
        private static let nonShiftModifierMask: UInt32 = 0x1C0000  // Cmd|Opt|Ctrl

        static let `default` = HotkeyCombo(keyCode: 15, modifiers: 0x120000) // Cmd+Shift+R
        static let discardDefault = HotkeyCombo(keyCode: 15, modifiers: 0x1A0000) // Cmd+Opt+Shift+R
        static let pauseDefault = HotkeyCombo(keyCode: 35, modifiers: 0x120000) // Cmd+Shift+P

        var isUsableGlobalShortcut: Bool {
            modifiers & Self.nonShiftModifierMask != 0
        }

        var displayString: String {
            var parts: [String] = []
            if modifiers & 0x40000 != 0 { parts.append("⌃") }  // Control
            if modifiers & 0x80000 != 0 { parts.append("⌥") }  // Option
            if modifiers & 0x20000 != 0 { parts.append("⇧") }  // Shift
            if modifiers & 0x100000 != 0 { parts.append("⌘") } // Command

            let keyString = keyCodeToString(keyCode)
            parts.append(keyString)
            return parts.joined()
        }

        private static let keyCodeNames: [UInt16: String] = [
            // Letters
            KeyCode.a: "A", KeyCode.b: "B", KeyCode.c: "C", KeyCode.d: "D",
            KeyCode.e: "E", KeyCode.f: "F", KeyCode.g: "G", KeyCode.h: "H",
            KeyCode.i: "I", KeyCode.j: "J", KeyCode.k: "K", KeyCode.l: "L",
            KeyCode.m: "M", KeyCode.n: "N", KeyCode.o: "O", KeyCode.p: "P",
            KeyCode.q: "Q", KeyCode.r: "R", KeyCode.s: "S", KeyCode.t: "T",
            KeyCode.u: "U", KeyCode.v: "V", KeyCode.w: "W", KeyCode.x: "X",
            KeyCode.y: "Y", KeyCode.z: "Z",
            // Numbers
            KeyCode.zero: "0", KeyCode.one: "1", KeyCode.two: "2",
            KeyCode.three: "3", KeyCode.four: "4", KeyCode.five: "5",
            KeyCode.six: "6", KeyCode.seven: "7", KeyCode.eight: "8",
            KeyCode.nine: "9",
            // Function keys
            KeyCode.f1: "F1", KeyCode.f2: "F2", KeyCode.f3: "F3",
            KeyCode.f4: "F4", KeyCode.f5: "F5", KeyCode.f6: "F6",
            KeyCode.f7: "F7", KeyCode.f8: "F8", KeyCode.f9: "F9",
            KeyCode.f10: "F10", KeyCode.f11: "F11", KeyCode.f12: "F12",
            // Special keys
            KeyCode.space: "Space", KeyCode.return: "↩", KeyCode.tab: "⇥",
            KeyCode.delete: "⌫", KeyCode.forwardDelete: "⌦", KeyCode.escape: "⎋",
        ]

        private func keyCodeToString(_ keyCode: UInt16) -> String {
            Self.keyCodeNames[keyCode] ?? "?"
        }
    }

    private static func loadHotkey(
        from defaults: UserDefaults,
        key: String,
        fallback: HotkeyCombo
    ) -> HotkeyCombo {
        if let data = defaults.data(forKey: key) {
            do {
                let combo = try JSONDecoder().decode(HotkeyCombo.self, from: data)
                // Migrate old broken default modifier value (0x180500) to new correct value (0x120000)
                // Old value masked to 0x100000 (Cmd only), new value masks to 0x120000 (Cmd+Shift)
                if combo.keyCode == HotkeyCombo.default.keyCode && combo.modifiers == 0x180500 {
                    logger.info("Migrating hotkey from old modifier format")
                    return fallback
                }
                guard combo.isUsableGlobalShortcut else {
                    logger.warning("Stored hotkey \(key) is not suitable for a global shortcut; falling back to default")
                    return fallback
                }
                return combo
            } catch {
                logger.warning("Failed to decode stored hotkey \(key): \(error.localizedDescription)")
            }
        }

        return fallback
    }

    private init() {
        let defaults = UserDefaults.standard

        self.launchAtLogin = defaults.bool(forKey: DefaultsKey.launchAtLogin)
        self.hasShownWelcome = defaults.bool(forKey: DefaultsKey.hasShownWelcome)
        self.showCursor = defaults.object(forKey: DefaultsKey.showCursor) as? Bool ?? true
        self.highlightClicks = defaults.object(forKey: DefaultsKey.highlightClicks) as? Bool ?? true
        self.frameWindowRecordings = defaults.bool(forKey: DefaultsKey.frameWindowRecordings)
        self.windowBackground = WindowBackground.fromStored(defaults.string(forKey: DefaultsKey.windowBackground)) ?? .charcoal
        self.frameRate = Self.sanitizedFrameRate(defaults.object(forKey: DefaultsKey.frameRate) as? Int ?? Self.defaultFrameRate)
        self.videoQuality = VideoQuality.fromStored(defaults.string(forKey: DefaultsKey.videoQuality)) ?? .medium
        self.videoResolution = VideoResolution.fromStored(defaults.string(forKey: DefaultsKey.videoResolution)) ?? .native
        self.videoCodec = VideoCodec.fromStored(defaults.string(forKey: DefaultsKey.videoCodec)) ?? .h264
        self.openFinderAfterRecording = defaults.object(forKey: DefaultsKey.openFinderAfterRecording) as? Bool ?? true
        self.showPreviewAfterRecording = defaults.object(forKey: DefaultsKey.showPreviewAfterRecording) as? Bool ?? true
        self.playSoundCues = defaults.object(forKey: DefaultsKey.playSoundCues) as? Bool ?? true

        if let path = defaults.string(forKey: DefaultsKey.outputDirectory) {
            let candidate = URL(fileURLWithPath: path, isDirectory: true)
            if Self.isWritableDirectory(candidate) {
                self.outputDirectory = candidate
            } else {
                logger.warning("Stored outputDirectory is invalid, using default: \(path)")
                let fallbackDirectory = Self.defaultOutputDirectory()
                self.outputDirectory = fallbackDirectory
                defaults.set(fallbackDirectory.path(), forKey: DefaultsKey.outputDirectory)
            }
        } else {
            self.outputDirectory = Self.defaultOutputDirectory()
        }

        self.askWhereToSave = defaults.bool(forKey: DefaultsKey.askWhereToSave)

        self.recordingHotkey = Self.loadHotkey(
            from: defaults,
            key: DefaultsKey.recordingHotkey,
            fallback: .default
        )
        self.discardHotkey = Self.loadHotkey(
            from: defaults,
            key: DefaultsKey.discardHotkey,
            fallback: .discardDefault
        )
        self.pauseHotkey = Self.loadHotkey(
            from: defaults,
            key: DefaultsKey.pauseHotkey,
            fallback: .pauseDefault
        )

        self.countdownDuration = Self.sanitizedCountdownDuration(
            defaults.object(forKey: DefaultsKey.countdownDuration) as? Int ?? 3
        )

        self.recordAudio = defaults.bool(forKey: DefaultsKey.recordAudio)
        self.audioSource = AudioSource.fromStored(defaults.string(forKey: DefaultsKey.audioSource)) ?? .microphone
        self.audioDeviceID = defaults.string(forKey: DefaultsKey.audioDeviceID)

        self.recordCamera = defaults.bool(forKey: DefaultsKey.recordCamera)
        self.cameraDeviceID = defaults.string(forKey: DefaultsKey.cameraDeviceID)
        self.cameraPosition = CameraOverlayPosition.fromStored(defaults.string(forKey: DefaultsKey.cameraPosition)) ?? .bottomRight
        if let storedFraction = defaults.object(forKey: DefaultsKey.cameraSizeFraction) as? Double {
            self.cameraSizeFraction = Self.sanitizedCameraSizeFraction(storedFraction)
        } else {
            // Migrate from the legacy Small/Medium/Large preset key.
            let legacyPreset = CameraOverlaySize.fromStored(defaults.string(forKey: DefaultsKey.cameraSize)) ?? .medium
            self.cameraSizeFraction = legacyPreset.fraction
        }
        self.cameraShape = CameraOverlayShape.fromStored(defaults.string(forKey: DefaultsKey.cameraShape)) ?? .circle

        self.textOverlayEnabled = defaults.bool(forKey: DefaultsKey.textOverlayEnabled)
        self.textOverlayText = defaults.string(forKey: DefaultsKey.textOverlayText) ?? ""
        self.textOverlayPosition = TextOverlayPosition.fromStored(defaults.string(forKey: DefaultsKey.textOverlayPosition)) ?? .center

        self.recentRecordingPaths = defaults.stringArray(forKey: DefaultsKey.recentRecordings) ?? []
        self.rememberedTarget = Self.loadRememberedTarget(from: defaults)
    }

    private func updateLaunchAtLogin() {
        launchAtLoginError = nil
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to update launch at login: \(error)")
            launchAtLoginError = SettingsErrorText.launchAtLoginUpdateFailed
            isSyncingLaunchAtLogin = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isSyncingLaunchAtLogin = false
        }
    }

    func checkLaunchAtLoginStatus() {
        launchAtLoginError = nil
        let isEnabled = SMAppService.mainApp.status == .enabled
        // Only update if different, and skip the registration call since we're just syncing state
        if launchAtLogin != isEnabled {
            isSyncingLaunchAtLogin = true
            launchAtLogin = isEnabled
            isSyncingLaunchAtLogin = false
        }
    }
}
