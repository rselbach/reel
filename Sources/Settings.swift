import CoreGraphics
import Foundation
import ServiceManagement

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin()
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
            UserDefaults.standard.set(outputDirectory.path, forKey: "outputDirectory")
        }
    }

    @Published var askWhereToSave: Bool {
        didSet { UserDefaults.standard.set(askWhereToSave, forKey: "askWhereToSave") }
    }

    @Published var openFinderAfterRecording: Bool {
        didSet { UserDefaults.standard.set(openFinderAfterRecording, forKey: "openFinderAfterRecording") }
    }

    @Published var recordingHotkey: HotkeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(recordingHotkey) {
                UserDefaults.standard.set(data, forKey: "recordingHotkey")
            }
        }
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

        static let `default` = HotkeyCombo(keyCode: 15, modifiers: 0x180500) // Cmd+Shift+R

        var displayString: String {
            var parts: [String] = []
            if modifiers & UInt32(CGEventFlags.maskControl.rawValue) != 0 { parts.append("⌃") }
            if modifiers & UInt32(CGEventFlags.maskAlternate.rawValue) != 0 { parts.append("⌥") }
            if modifiers & UInt32(CGEventFlags.maskShift.rawValue) != 0 { parts.append("⇧") }
            if modifiers & UInt32(CGEventFlags.maskCommand.rawValue) != 0 { parts.append("⌘") }

            let keyString = keyCodeToString(keyCode)
            parts.append(keyString)
            return parts.joined()
        }

        private func keyCodeToString(_ keyCode: UInt16) -> String {
            let keyMap: [UInt16: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
                8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
                38: "J", 40: "K", 45: "N", 46: "M"
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

        if let path = defaults.string(forKey: "outputDirectory") {
            self.outputDirectory = URL(fileURLWithPath: path)
        } else {
            self.outputDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        }

        self.askWhereToSave = defaults.bool(forKey: "askWhereToSave")

        if let data = defaults.data(forKey: "recordingHotkey"),
           let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            self.recordingHotkey = combo
        } else {
            self.recordingHotkey = .default
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
    }

    func checkLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
