import AVFoundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "SettingsView")

enum SettingsText {
    static let generalTab = "General"
    static let recordingTab = "Recording"
    static let shortcutsTab = "Shortcuts"
    static let launchAtLogin = "Launch at login"
    static let saveRecordingsTo = "Save recordings to:"
    static let askEachTime = "Ask each time"
    static let fixedFolder = "Fixed folder"
    static let outputFolder = "Output folder:"
    static let choose = "Choose..."
    static let outputDirectoryNotWritable = "Cannot write to selected folder. Pick another location."
    static let openFinderAfterRecording = "Open Finder after recording"
    static let showPreviewAfterRecording = "Show preview after recording"
    static let showCursor = "Show cursor in recording"
    static let frameRate = "Frame rate:"
    static let videoQuality = "Video quality:"
    static let countdown = "Countdown:"
    static let countdownOff = "Off"
    static let recordAudio = "Record audio"
    static let audioSource = "Source:"
    static let audioInput = "Microphone:"
    static let recordCamera = "Record camera overlay"
    static let camera = "Camera:"
    static let position = "Position:"
    static let size = "Size:"
    static let shape = "Shape:"
    static let addTextOverlay = "Add text overlay"
    static let text = "Text:"
    static let toggleRecording = "Toggle recording:"
    static let pressShortcut = "Press shortcut..."
    static let shortcutHelp = "Press the button and type your desired shortcut."
    static let defaultDevice = "Default"
    static let unavailableDevice = "Unavailable device"
}

enum SettingsLayout {
    static let width: CGFloat = 460
    /// The Recording tab grows well past this once camera and text overlay
    /// are both enabled, so tab content scrolls rather than clipping.
    static let height: CGFloat = 480
}

/// Wraps a settings tab so content taller than the window scrolls instead of
/// being silently cut off at the bottom.
private struct ScrollingTab<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            ScrollingTab { GeneralTab(settings: settings) }
                .tabItem {
                    Label(SettingsText.generalTab, systemImage: "gear")
                }

            ScrollingTab { RecordingTab(settings: settings) }
                .tabItem {
                    Label(SettingsText.recordingTab, systemImage: "video")
                }

            ScrollingTab { ShortcutsTab(settings: settings) }
                .tabItem {
                    Label(SettingsText.shortcutsTab, systemImage: "keyboard")
                }
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .padding()
    }
}

struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @State private var outputDirectoryError: String?

    var body: some View {
        Form {
            Toggle(SettingsText.launchAtLogin, isOn: $settings.launchAtLogin)

            Picker(SettingsText.saveRecordingsTo, selection: $settings.askWhereToSave) {
                Text(SettingsText.askEachTime).tag(true)
                Text(SettingsText.fixedFolder).tag(false)
            }

            if !settings.askWhereToSave {
                HStack {
                    Text(SettingsText.outputFolder)
                    Text(settings.outputDirectory.path())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(SettingsText.choose) {
                        selectOutputDirectory()
                    }
                }
                if let outputDirectoryError {
                    Text(outputDirectoryError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Toggle(SettingsText.openFinderAfterRecording, isOn: $settings.openFinderAfterRecording)
            Toggle(SettingsText.showPreviewAfterRecording, isOn: $settings.showPreviewAfterRecording)
            if let launchError = settings.launchAtLoginError {
                Text(launchError)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputDirectory

        if panel.runModal() == .OK, let url = panel.url {
            guard isValidWritableDirectory(url) else {
                outputDirectoryError = SettingsText.outputDirectoryNotWritable
                return
            }
            outputDirectoryError = nil
            settings.outputDirectory = url
        }
    }

    private func isValidWritableDirectory(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return false }
            return FileManager.default.isWritableFile(atPath: url.path())
        } catch {
            logger.warning("Failed to read directory attributes for \(url.path()): \(error.localizedDescription)")
            return false
        }
    }
}

struct DevicePicker: View {
    let title: String
    let devices: [AVCaptureDevice]
    @Binding var selection: String?

    var body: some View {
        Picker(title, selection: $selection) {
            Text(SettingsText.defaultDevice).tag(nil as String?)
            if let selection, !devices.contains(where: { $0.uniqueID == selection }) {
                Text(SettingsText.unavailableDevice).tag(selection as String?)
            }
            ForEach(devices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(device.uniqueID as String?)
            }
        }
    }
}

struct RecordingTab: View {
    @ObservedObject var settings: AppSettings

    /// Presets write their fraction; a corner-drag size that matches no
    /// preset shows as a "Custom (n%)" entry instead of lying about which
    /// preset is active.
    private var cameraSizeSelection: Binding<AppSettings.CameraOverlaySize?> {
        Binding(
            get: { settings.cameraSizePreset },
            set: { preset in
                if let preset {
                    settings.cameraSizeFraction = preset.fraction
                }
            }
        )
    }

    var body: some View {
        Form {
            Toggle(SettingsText.showCursor, isOn: $settings.showCursor)

            Picker(SettingsText.frameRate, selection: $settings.frameRate) {
                ForEach(AppSettings.supportedFrameRates, id: \.self) { frameRate in
                    Text("\(frameRate) fps").tag(frameRate)
                }
            }

            Picker(SettingsText.videoQuality, selection: $settings.videoQuality) {
                ForEach(AppSettings.VideoQuality.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }

            Picker(SettingsText.countdown, selection: $settings.countdownDuration) {
                ForEach(AppSettings.supportedCountdownDurations, id: \.self) { duration in
                    Text(duration == 0 ? SettingsText.countdownOff : "\(duration) seconds").tag(duration)
                }
            }

            Divider()

            Toggle(SettingsText.recordAudio, isOn: $settings.recordAudio)

            if settings.recordAudio {
                Picker(SettingsText.audioSource, selection: $settings.audioSource) {
                    ForEach(AppSettings.AudioSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }

                if settings.audioSource == .microphone {
                    DevicePicker(
                        title: SettingsText.audioInput,
                        devices: settings.availableAudioDevices,
                        selection: $settings.audioDeviceID
                    )
                }
            }

            Divider()

            Toggle(SettingsText.recordCamera, isOn: $settings.recordCamera)

            if settings.recordCamera {
                DevicePicker(
                    title: SettingsText.camera,
                    devices: settings.availableCameras,
                    selection: $settings.cameraDeviceID
                )

                Picker(SettingsText.position, selection: $settings.cameraPosition) {
                    ForEach(AppSettings.CameraOverlayPosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }

                Picker(SettingsText.size, selection: cameraSizeSelection) {
                    ForEach(AppSettings.CameraOverlaySize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size as AppSettings.CameraOverlaySize?)
                    }
                    if settings.cameraSizePreset == nil {
                        Text("Custom (\(Int((settings.cameraSizeFraction * 100).rounded()))%)")
                            .tag(nil as AppSettings.CameraOverlaySize?)
                    }
                }

                Picker(SettingsText.shape, selection: $settings.cameraShape) {
                    ForEach(AppSettings.CameraOverlayShape.allCases, id: \.self) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
            }

            Divider()

            Toggle(SettingsText.addTextOverlay, isOn: $settings.textOverlayEnabled)

            if settings.textOverlayEnabled {
                HStack {
                    Text(SettingsText.text)
                    TextField("", text: $settings.textOverlayText)
                }

                Picker(SettingsText.position, selection: $settings.textOverlayPosition) {
                    ForEach(AppSettings.TextOverlayPosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }
            }
        }
    }
}

struct ShortcutsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var isRecordingHotkey = false

    var body: some View {
        Form {
            HStack {
                Text(SettingsText.toggleRecording)
                Spacer()
                Button(action: { isRecordingHotkey = true }) {
                    Text(isRecordingHotkey ? SettingsText.pressShortcut : settings.recordingHotkey.displayString)
                        .frame(minWidth: 100)
                }
                .background(HotkeyRecorder(
                    isRecording: $isRecordingHotkey,
                    hotkey: $settings.recordingHotkey
                ))
            }

            Text(SettingsText.shortcutHelp)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var hotkey: AppSettings.HotkeyCombo

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView()
        view.onHotkeyRecorded = { keyCode, modifiers in
            hotkey = AppSettings.HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        if isRecording {
            nsView.startRecording()
        } else {
            nsView.stopRecording()
        }
    }
}

enum HotkeyRecorderLogic {
    enum Decision: Equatable {
        case cancel
        case record(keyCode: UInt16, modifiers: UInt32)
        case reject
        case passThrough
    }

    static func decision(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Decision {
        if keyCode == KeyCode.escape {
            return .cancel
        }

        guard modifierFlags.contains(.command) ||
              modifierFlags.contains(.control) ||
              modifierFlags.contains(.option) ||
              modifierFlags.contains(.shift) else {
            return .passThrough
        }

        let modifiers = UInt32(modifierFlags.rawValue) & AppSettings.HotkeyCombo.modifierMask
        let combo = AppSettings.HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        guard combo.isUsableGlobalShortcut else {
            return .reject
        }

        return .record(keyCode: keyCode, modifiers: modifiers)
    }
}

class HotkeyRecorderView: NSView {
    var onHotkeyRecorded: ((UInt16, UInt32) -> Void)?
    var onCancel: (() -> Void)?
    private nonisolated(unsafe) var monitor: Any?

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func startRecording() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            switch HotkeyRecorderLogic.decision(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            case .cancel:
                self?.onCancel?()
                return nil
            case .record(let keyCode, let modifiers):
                self?.onHotkeyRecorded?(keyCode, modifiers)
                return nil
            case .reject:
                NSSound.beep()
                return nil
            case .passThrough:
                return event
            }
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

}
