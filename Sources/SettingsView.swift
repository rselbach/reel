import AVFoundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "SettingsView")

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            RecordingTab(settings: settings)
                .tabItem {
                    Label("Recording", systemImage: "video")
                }

            ShortcutsTab(settings: settings)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .frame(width: 460, height: 420)
        .padding()
    }
}

struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @State private var outputDirectoryError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)

            Picker("Save recordings to:", selection: $settings.askWhereToSave) {
                Text("Ask each time").tag(true)
                Text("Fixed folder").tag(false)
            }

            if !settings.askWhereToSave {
                HStack {
                    Text("Output folder:")
                    Text(settings.outputDirectory.path())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Choose...") {
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

            Toggle("Open Finder after recording", isOn: $settings.openFinderAfterRecording)
            Toggle("Show preview after recording", isOn: $settings.showPreviewAfterRecording)
            if let launchError = settings.launchAtLoginError {
                Text(launchError)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
        .padding()
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
                outputDirectoryError = "Cannot write to selected folder. Pick another location."
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
            Text("Default").tag(nil as String?)
            ForEach(devices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(device.uniqueID as String?)
            }
        }
    }
}

struct RecordingTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Show cursor in recording", isOn: $settings.showCursor)

            Picker("Frame rate:", selection: $settings.frameRate) {
                ForEach(AppSettings.supportedFrameRates, id: \.self) { frameRate in
                    Text("\(frameRate) fps").tag(frameRate)
                }
            }

            Picker("Video quality:", selection: $settings.videoQuality) {
                ForEach(AppSettings.VideoQuality.allCases, id: \.self) { quality in
                    Text(quality.rawValue).tag(quality)
                }
            }

            Divider()

            Toggle("Record audio from microphone", isOn: $settings.recordAudio)

            if settings.recordAudio {
                DevicePicker(
                    title: "Audio input:",
                    devices: settings.availableAudioDevices,
                    selection: $settings.audioDeviceID
                )
            }

            Divider()

            Toggle("Record camera overlay", isOn: $settings.recordCamera)

            if settings.recordCamera {
                DevicePicker(
                    title: "Camera:",
                    devices: settings.availableCameras,
                    selection: $settings.cameraDeviceID
                )

                Picker("Position:", selection: $settings.cameraPosition) {
                    ForEach(AppSettings.CameraOverlayPosition.allCases, id: \.self) { position in
                        Text(position.rawValue).tag(position)
                    }
                }

                Picker("Size:", selection: $settings.cameraSize) {
                    ForEach(AppSettings.CameraOverlaySize.allCases, id: \.self) { size in
                        Text(size.rawValue).tag(size)
                    }
                }

                Picker("Shape:", selection: $settings.cameraShape) {
                    ForEach(AppSettings.CameraOverlayShape.allCases, id: \.self) { shape in
                        Text(shape.rawValue).tag(shape)
                    }
                }
            }

            Divider()

            Toggle("Add text overlay", isOn: $settings.textOverlayEnabled)

            if settings.textOverlayEnabled {
                HStack {
                    Text("Text:")
                    TextField("CONFIDENTIAL. DO NOT SHARE", text: $settings.textOverlayText)
                }

                Picker("Position:", selection: $settings.textOverlayPosition) {
                    ForEach(AppSettings.TextOverlayPosition.allCases, id: \.self) { position in
                        Text(position.rawValue).tag(position)
                    }
                }
            }
        }
        .padding()
    }
}

struct ShortcutsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var isRecordingHotkey = false

    var body: some View {
        Form {
            HStack {
                Text("Toggle recording:")
                Spacer()
                Button(action: { isRecordingHotkey = true }) {
                    Text(isRecordingHotkey ? "Press shortcut..." : settings.recordingHotkey.displayString)
                        .frame(minWidth: 100)
                }
                .background(HotkeyRecorder(
                    isRecording: $isRecordingHotkey,
                    hotkey: $settings.recordingHotkey
                ))
            }

            Text("Press the button and type your desired shortcut.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
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
            if event.keyCode == KeyCode.escape {
                self?.onCancel?()
                return nil
            } else if event.modifierFlags.contains(.command) ||
                      event.modifierFlags.contains(.control) ||
                      event.modifierFlags.contains(.option) ||
                      event.modifierFlags.contains(.shift) {
                // Mask to device-independent bits only for cross-API compatibility
                let modifiers = UInt32(event.modifierFlags.rawValue) & AppSettings.HotkeyCombo.modifierMask
                self?.onHotkeyRecorded?(event.keyCode, modifiers)
                return nil
            }
            return event
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

}
