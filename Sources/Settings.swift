import AVFoundation
import CoreGraphics
import Foundation
import os.log
import ServiceManagement

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "Settings")

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

    private func persist(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            persist(launchAtLogin, key: "launchAtLogin")
            if !isSyncingLaunchAtLogin {
                updateLaunchAtLogin()
            }
        }
    }

    @Published var showCursor: Bool {
        didSet { persist(showCursor, key: "showCursor") }
    }

    @Published var frameRate: Int {
        didSet {
            let sanitized = Self.sanitizedFrameRate(frameRate)
            if sanitized != frameRate {
                frameRate = sanitized
                return
            }
            persist(frameRate, key: "frameRate")
        }
    }

    @Published var videoQuality: VideoQuality {
        didSet { persist(videoQuality.rawValue, key: "videoQuality") }
    }

    @Published var outputDirectory: URL {
        didSet {
            persist(outputDirectory.path(), key: "outputDirectory")
        }
    }

    @Published var askWhereToSave: Bool {
        didSet { persist(askWhereToSave, key: "askWhereToSave") }
    }

    @Published var openFinderAfterRecording: Bool {
        didSet { persist(openFinderAfterRecording, key: "openFinderAfterRecording") }
    }

    @Published var showPreviewAfterRecording: Bool {
        didSet { persist(showPreviewAfterRecording, key: "showPreviewAfterRecording") }
    }

    static let hotkeyChangedNotification = Notification.Name("AppSettingsHotkeyChanged")

    @Published var recordingHotkey: HotkeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(recordingHotkey) {
                UserDefaults.standard.set(data, forKey: "recordingHotkey")
            }
            HotkeyManager.shared.updateCachedHotkey(recordingHotkey)
            NotificationCenter.default.post(name: Self.hotkeyChangedNotification, object: nil)
        }
    }

    @Published var recordAudio: Bool {
        didSet { persist(recordAudio, key: "recordAudio") }
    }

    @Published var audioDeviceID: String? {
        didSet { persist(audioDeviceID, key: "audioDeviceID") }
    }

    @Published var recordCamera: Bool {
        didSet { persist(recordCamera, key: "recordCamera") }
    }

    @Published var cameraDeviceID: String? {
        didSet { persist(cameraDeviceID, key: "cameraDeviceID") }
    }

    @Published var cameraPosition: CameraOverlayPosition {
        didSet { persist(cameraPosition.rawValue, key: "cameraPosition") }
    }

    @Published var cameraSize: CameraOverlaySize {
        didSet { persist(cameraSize.rawValue, key: "cameraSize") }
    }

    @Published var cameraShape: CameraOverlayShape {
        didSet { persist(cameraShape.rawValue, key: "cameraShape") }
    }

    enum CameraOverlayPosition: String, CaseIterable {
        case bottomLeft = "Bottom Left"
        case bottomRight = "Bottom Right"
        case topLeft = "Top Left"
        case topRight = "Top Right"

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

    enum CameraOverlaySize: String, CaseIterable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"

        var fraction: CGFloat {
            switch self {
            case .small: return 0.15
            case .medium: return 0.2
            case .large: return 0.25
            }
        }
    }

    enum CameraOverlayShape: String, CaseIterable {
        case rectangle = "Rectangle"
        case circle = "Circle"
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
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 13.0, *) {
            deviceTypes.append(.deskViewCamera)
        }
        if #available(macOS 14.0, *) {
            deviceTypes.append(.continuityCamera)
        }
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

    enum VideoQuality: String, CaseIterable {
        case low = "Low (5 Mbps)"
        case medium = "Medium (10 Mbps)"
        case high = "High (20 Mbps)"
        case maximum = "Maximum (50 Mbps)"

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

    static func sanitizedFrameRate(_ frameRate: Int) -> Int {
        guard frameRate > 0 else { return 60 }
        if supportedFrameRates.contains(frameRate) { return frameRate }

        let closest = supportedFrameRates.min(by: { abs($0 - frameRate) < abs($1 - frameRate) }) ?? 60
        return closest
    }

    struct HotkeyCombo: Codable, Equatable {
        var keyCode: UInt16
        var modifiers: UInt32

        // Device-independent modifier mask (works for both NSEvent and CGEvent)
        static let modifierMask: UInt32 = 0x1E0000  // Cmd|Opt|Ctrl|Shift

        static let `default` = HotkeyCombo(keyCode: 15, modifiers: 0x120000) // Cmd+Shift+R

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

    private static func loadRecordingHotkey(from defaults: UserDefaults) -> HotkeyCombo {
        if let data = defaults.data(forKey: "recordingHotkey"),
           let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            // Migrate old broken default modifier value (0x180500) to new correct value (0x120000)
            // Old value masked to 0x100000 (Cmd only), new value masks to 0x120000 (Cmd+Shift)
            if combo.keyCode == HotkeyCombo.default.keyCode && combo.modifiers == 0x180500 {
                logger.info("Migrating hotkey from old modifier format")
                return .default
            }
            return combo
        }

        return .default
    }

    private init() {
        let defaults = UserDefaults.standard

        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.showCursor = defaults.object(forKey: "showCursor") as? Bool ?? true
        self.frameRate = Self.sanitizedFrameRate(defaults.object(forKey: "frameRate") as? Int ?? 60)
        self.videoQuality = VideoQuality(rawValue: defaults.string(forKey: "videoQuality") ?? "") ?? .medium
        self.openFinderAfterRecording = defaults.object(forKey: "openFinderAfterRecording") as? Bool ?? true
        self.showPreviewAfterRecording = defaults.object(forKey: "showPreviewAfterRecording") as? Bool ?? true

        if let path = defaults.string(forKey: "outputDirectory") {
            let candidate = URL(fileURLWithPath: path, isDirectory: true)
            if let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey]),
               values.isDirectory == true {
                self.outputDirectory = candidate
            } else {
                logger.warning("Stored outputDirectory is invalid, using default: \(path)")
                self.outputDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory())
                persist(self.outputDirectory.path(), key: "outputDirectory")
            }
        } else {
            self.outputDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }

        self.askWhereToSave = defaults.bool(forKey: "askWhereToSave")

        self.recordingHotkey = Self.loadRecordingHotkey(from: defaults)

        self.recordAudio = defaults.bool(forKey: "recordAudio")
        self.audioDeviceID = defaults.string(forKey: "audioDeviceID")

        self.recordCamera = defaults.bool(forKey: "recordCamera")
        self.cameraDeviceID = defaults.string(forKey: "cameraDeviceID")
        self.cameraPosition = CameraOverlayPosition(rawValue: defaults.string(forKey: "cameraPosition") ?? "") ?? .bottomRight
        self.cameraSize = CameraOverlaySize(rawValue: defaults.string(forKey: "cameraSize") ?? "") ?? .medium
        self.cameraShape = CameraOverlayShape(rawValue: defaults.string(forKey: "cameraShape") ?? "") ?? .circle
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to update launch at login: \(error)")
        }
    }

    func checkLaunchAtLoginStatus() {
        let isEnabled = SMAppService.mainApp.status == .enabled
        // Only update if different, and skip the registration call since we're just syncing state
        if launchAtLogin != isEnabled {
            isSyncingLaunchAtLogin = true
            launchAtLogin = isEnabled
            isSyncingLaunchAtLogin = false
        }
    }
}
