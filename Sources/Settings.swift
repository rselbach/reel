import AVFoundation
import CoreGraphics
import Foundation
import os.log
import ServiceManagement

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.reel", category: "Settings")

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

    private var isCheckingLaunchStatus = false

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            if !isCheckingLaunchStatus {
                updateLaunchAtLogin()
            }
        }
    }

    @Published var showCursor: Bool {
        didSet { UserDefaults.standard.set(showCursor, forKey: "showCursor") }
    }

    @Published var frameRate: Int {
        didSet { UserDefaults.standard.set(frameRate, forKey: "frameRate") }
    }

    @Published var videoQuality: VideoQuality {
        didSet { UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality") }
    }

    @Published var outputDirectory: URL {
        didSet {
            UserDefaults.standard.set(outputDirectory.path(), forKey: "outputDirectory")
        }
    }

    @Published var askWhereToSave: Bool {
        didSet { UserDefaults.standard.set(askWhereToSave, forKey: "askWhereToSave") }
    }

    @Published var openFinderAfterRecording: Bool {
        didSet { UserDefaults.standard.set(openFinderAfterRecording, forKey: "openFinderAfterRecording") }
    }

    @Published var showPreviewAfterRecording: Bool {
        didSet { UserDefaults.standard.set(showPreviewAfterRecording, forKey: "showPreviewAfterRecording") }
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
        didSet { UserDefaults.standard.set(recordAudio, forKey: "recordAudio") }
    }

    @Published var audioDeviceID: String? {
        didSet { UserDefaults.standard.set(audioDeviceID, forKey: "audioDeviceID") }
    }

    @Published var recordCamera: Bool {
        didSet { UserDefaults.standard.set(recordCamera, forKey: "recordCamera") }
    }

    @Published var cameraDeviceID: String? {
        didSet { UserDefaults.standard.set(cameraDeviceID, forKey: "cameraDeviceID") }
    }

    @Published var cameraPosition: CameraOverlayPosition {
        didSet { UserDefaults.standard.set(cameraPosition.rawValue, forKey: "cameraPosition") }
    }

    @Published var cameraSize: CameraOverlaySize {
        didSet { UserDefaults.standard.set(cameraSize.rawValue, forKey: "cameraSize") }
    }

    @Published var cameraShape: CameraOverlayShape {
        didSet { UserDefaults.standard.set(cameraShape.rawValue, forKey: "cameraShape") }
    }

    enum CameraOverlayPosition: String, CaseIterable {
        case bottomLeft = "Bottom Left"
        case bottomRight = "Bottom Right"
        case topLeft = "Top Left"
        case topRight = "Top Right"
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
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
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

        private func keyCodeToString(_ keyCode: UInt16) -> String {
            let keyMap: [UInt16: String] = [
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
            return keyMap[keyCode] ?? "?"
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.showCursor = defaults.object(forKey: "showCursor") as? Bool ?? true
        self.frameRate = defaults.object(forKey: "frameRate") as? Int ?? 60
        self.videoQuality = VideoQuality(rawValue: defaults.string(forKey: "videoQuality") ?? "") ?? .medium
        self.openFinderAfterRecording = defaults.object(forKey: "openFinderAfterRecording") as? Bool ?? true
        self.showPreviewAfterRecording = defaults.object(forKey: "showPreviewAfterRecording") as? Bool ?? true

        if let path = defaults.string(forKey: "outputDirectory") {
            self.outputDirectory = URL(fileURLWithPath: path)
        } else {
            self.outputDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        }

        self.askWhereToSave = defaults.bool(forKey: "askWhereToSave")

        if let data = defaults.data(forKey: "recordingHotkey"),
           let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            // Migrate old broken default modifier value (0x180500) to new correct value (0x120000)
            // Old value masked to 0x100000 (Cmd only), new value masks to 0x120000 (Cmd+Shift)
            if combo.keyCode == HotkeyCombo.default.keyCode && combo.modifiers == 0x180500 {
                logger.info("Migrating hotkey from old modifier format")
                self.recordingHotkey = .default
            } else {
                self.recordingHotkey = combo
            }
        } else {
            self.recordingHotkey = .default
        }

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
            isCheckingLaunchStatus = true
            launchAtLogin = isEnabled
            isCheckingLaunchStatus = false
        }
    }
}
