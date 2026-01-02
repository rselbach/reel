import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var isRecordingHotkey = false

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

            ShortcutsTab(settings: settings, isRecordingHotkey: $isRecordingHotkey)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .frame(width: 450, height: 320)
        .padding()
    }
}

struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

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
                    Text(settings.outputDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Choose...") {
                        selectOutputDirectory()
                    }
                }
            }

            Toggle("Open Finder after recording", isOn: $settings.openFinderAfterRecording)
            Toggle("Show preview after recording", isOn: $settings.showPreviewAfterRecording)
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
            settings.outputDirectory = url
        }
    }
}

struct RecordingTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Show cursor in recording", isOn: $settings.showCursor)

            Picker("Frame rate:", selection: $settings.frameRate) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }

            Picker("Video quality:", selection: $settings.videoQuality) {
                ForEach(AppSettings.VideoQuality.allCases, id: \.self) { quality in
                    Text(quality.rawValue).tag(quality)
                }
            }

            Divider()

            Toggle("Record audio from microphone", isOn: $settings.recordAudio)

            if settings.recordAudio {
                Picker("Audio input:", selection: $settings.audioDeviceID) {
                    Text("Default").tag(nil as String?)
                    ForEach(settings.availableAudioDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID as String?)
                    }
                }
            }

            Divider()

            Toggle("Record camera overlay", isOn: $settings.recordCamera)

            if settings.recordCamera {
                Picker("Camera:", selection: $settings.cameraDeviceID) {
                    Text("Default").tag(nil as String?)
                    ForEach(settings.availableCameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID as String?)
                    }
                }

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
            }
        }
        .padding()
    }
}

struct ShortcutsTab: View {
    @ObservedObject var settings: AppSettings
    @Binding var isRecordingHotkey: Bool

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
    private var monitor: Any?

    func startRecording() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.onCancel?()
            } else if event.modifierFlags.contains(.command) ||
                      event.modifierFlags.contains(.control) ||
                      event.modifierFlags.contains(.option) {
                let modifiers = UInt32(event.modifierFlags.rawValue)
                self?.onHotkeyRecorded?(event.keyCode, modifiers)
            }
            return nil
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

}
