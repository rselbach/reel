import AVFoundation
import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "SettingsView")

enum SettingsText {
    static let launchAtLogin = "Launch at login"
    static let saving = "Saving"
    static let saveRecordingsTo = "Save recordings to"
    static let askEachTime = "Ask each time"
    static let fixedFolder = "Fixed folder"
    static let outputFolder = "Folder"
    static let choose = "Choose..."
    static let outputDirectoryNotWritable = "Cannot write to selected folder. Pick another location."
    static let whenRecordingEnds = "When a recording ends"
    static let playSoundCues = "Play a sound when recording starts and stops"
    static let capture = "Capture"
    static let format = "Format"
    static let showCursor = "Show cursor in recording"
    static let highlightClicks = "Highlight clicks"
    static let windowFraming = "Window Framing"
    static let frameWindowRecordings = "Frame window recordings on a background"
    static let windowBackgroundLabel = "Background"
    static let frameRate = "Frame rate"
    static let videoQuality = "Video quality"
    static let videoQualityFooter = "File size grows with the frame size and with how much changes on screen."
    static let videoResolution = "Resolution"
    static let videoCodec = "Codec"
    static let countdown = "Countdown"
    static let countdownOff = "Off"
    static let audio = "Audio"
    static let recordAudio = "Record audio"
    static let audioSource = "Source"
    static let audioInput = "Microphone"
    static let recordCamera = "Record camera overlay"
    static let camera = "Camera"
    static let position = "Position"
    static let size = "Size"
    static let shape = "Shape"
    static let textOverlay = "Text"
    static let addTextOverlay = "Add text overlay"
    static let text = "Text"
    static let textPrompt = "Shown on every frame"
    static let pressShortcut = "Press shortcut..."
    static let noShortcut = "None"
    static let turnOffShortcut = "Turn Off Shortcut"
    static let shortcutHelp = "Press the button and type your desired shortcut."
    static let restoreDefaultShortcuts = "Restore Default Shortcuts"
    static let defaultDevice = "Default"
    static let unavailableDevice = "Unavailable device"
}

/// What Reel shows once a take is saved. Stored as two settings because the
/// preview, when on, replaces the Finder reveal.
enum AfterRecordingAction: CaseIterable {
    case showPreview
    case revealInFinder
    case nothing

    init(showPreview: Bool, openFinder: Bool) {
        switch (showPreview, openFinder) {
        case (true, _): self = .showPreview
        case (false, true): self = .revealInFinder
        case (false, false): self = .nothing
        }
    }

    var displayName: String {
        switch self {
        case .showPreview: return "Show the preview"
        case .revealInFinder: return "Reveal it in Finder"
        case .nothing: return "Do nothing"
        }
    }

    var showsPreview: Bool { self == .showPreview }
    var revealsInFinder: Bool { self == .revealInFinder }
}

/// One toolbar tab of the Settings window.
enum SettingsPane: CaseIterable {
    case general
    case video
    case audioAndCamera
    case overlays
    case shortcuts

    var title: String {
        switch self {
        case .general: return "General"
        case .video: return "Video"
        case .audioAndCamera: return "Audio & Camera"
        case .overlays: return "Overlays"
        case .shortcuts: return "Shortcuts"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .video: return "video"
        case .audioAndCamera: return "mic"
        case .overlays: return "square.on.square"
        case .shortcuts: return "keyboard"
        }
    }

    @MainActor
    @ViewBuilder
    private var content: some View {
        let settings = AppSettings.shared
        switch self {
        case .general: GeneralPane(settings: settings)
        case .video: VideoPane(settings: settings)
        case .audioAndCamera: AudioAndCameraPane(settings: settings)
        case .overlays: OverlaysPane(settings: settings)
        case .shortcuts: ShortcutsPane(settings: settings)
        }
    }

    /// Toolbar tabs, one per pane. Each pane reports its natural height, so
    /// the window fits whichever pane is showing and grows with it.
    @MainActor
    static func makeTabViewController() -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // Keeps the window titled Reel Settings instead of renaming it after
        // each pane.
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for pane in allCases {
            let controller = NSHostingController(rootView: pane.content)
            controller.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        return tabs
    }
}

/// A grouped form with scrolling off, so it reports its natural height.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CaptionText: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @State private var outputDirectoryError: String?

    private var afterRecording: Binding<AfterRecordingAction> {
        Binding(
            get: {
                AfterRecordingAction(
                    showPreview: settings.showPreviewAfterRecording,
                    openFinder: settings.openFinderAfterRecording
                )
            },
            set: { action in
                settings.showPreviewAfterRecording = action.showsPreview
                settings.openFinderAfterRecording = action.revealsInFinder
            }
        )
    }

    var body: some View {
        SettingsForm {
            Section {
                Toggle(SettingsText.launchAtLogin, isOn: $settings.launchAtLogin)
                if let launchError = settings.launchAtLoginError {
                    CaptionText(launchError, color: .orange)
                }
                Toggle(SettingsText.playSoundCues, isOn: $settings.playSoundCues)
            }

            Section(SettingsText.saving) {
                Picker(SettingsText.saveRecordingsTo, selection: $settings.askWhereToSave) {
                    Text(SettingsText.askEachTime).tag(true)
                    Text(SettingsText.fixedFolder).tag(false)
                }

                if !settings.askWhereToSave {
                    LabeledContent(SettingsText.outputFolder) {
                        HStack(spacing: 8) {
                            OutputFolderLabel(url: settings.outputDirectory)
                            Button(SettingsText.choose) {
                                selectOutputDirectory()
                            }
                        }
                    }
                    if let outputDirectoryError {
                        CaptionText(outputDirectoryError, color: .red)
                    }
                }

                Picker(SettingsText.whenRecordingEnds, selection: afterRecording) {
                    ForEach(AfterRecordingAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
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
            return FileManager.default.isWritableFile(atPath: url.path(percentEncoded: false))
        } catch {
            logger.warning("Failed to read directory attributes for \(url.path(percentEncoded: false)): \(error.localizedDescription)")
            return false
        }
    }
}

/// The folder as Finder shows it, by icon and name. The full path is in the
/// tooltip rather than squeezed into the row.
private struct OutputFolderLabel: View {
    let url: URL

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 16, height: 16)
            Text(FileManager.default.displayName(atPath: url.path(percentEncoded: false)))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(url.path(percentEncoded: false))
        .accessibilityElement(children: .combine)
    }
}

struct VideoPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsForm {
            Section(SettingsText.capture) {
                Picker(SettingsText.countdown, selection: $settings.countdownDuration) {
                    ForEach(AppSettings.supportedCountdownDurations, id: \.self) { duration in
                        Text(duration == 0 ? SettingsText.countdownOff : "\(duration) seconds").tag(duration)
                    }
                }
                Toggle(SettingsText.showCursor, isOn: $settings.showCursor)
                Toggle(SettingsText.highlightClicks, isOn: $settings.highlightClicks)
            }

            Section {
                Picker(SettingsText.videoResolution, selection: $settings.videoResolution) {
                    ForEach(AppSettings.VideoResolution.allCases, id: \.self) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }

                Picker(SettingsText.frameRate, selection: $settings.frameRate) {
                    ForEach(AppSettings.supportedFrameRates, id: \.self) { frameRate in
                        Text("\(frameRate) fps").tag(frameRate)
                    }
                }

                Picker(SettingsText.videoCodec, selection: $settings.videoCodec) {
                    ForEach(AppSettings.VideoCodec.allCases, id: \.self) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }

                Picker(SettingsText.videoQuality, selection: $settings.videoQuality) {
                    ForEach(AppSettings.VideoQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
            } header: {
                Text(SettingsText.format)
            } footer: {
                CaptionText(SettingsText.videoQualityFooter)
            }
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

struct AudioAndCameraPane: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var levelMonitor = AudioLevelMonitor()

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

    private var shouldMeter: Bool {
        settings.recordAudio && settings.audioSource.capturesMicrophone
    }

    var body: some View {
        SettingsForm {
            Section(SettingsText.audio) {
                Toggle(SettingsText.recordAudio, isOn: $settings.recordAudio)

                if settings.recordAudio {
                    Picker(SettingsText.audioSource, selection: $settings.audioSource) {
                        ForEach(AppSettings.AudioSource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }

                    if settings.audioSource.capturesMicrophone {
                        DevicePicker(
                            title: SettingsText.audioInput,
                            devices: settings.availableAudioDevices,
                            selection: $settings.audioDeviceID
                        )

                        // A muted or misrouted input is otherwise only
                        // discovered after a take is already ruined.
                        LabeledContent(AudioLevelText.label) {
                            AudioLevelMeter(level: levelMonitor.level)
                                .frame(width: 160)
                        }

                        if let error = levelMonitor.errorMessage {
                            CaptionText(error, color: .orange)
                        }
                    }
                }
            }

            Section(SettingsText.camera) {
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
            }
        }
        .onAppear { refreshMetering() }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: shouldMeter) { refreshMetering() }
        .onChange(of: settings.audioDeviceID) { refreshMetering() }
        .onReceive(
            NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)
        ) { _ in
            settings.objectWillChange.send()
            refreshMetering()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)
        ) { _ in
            settings.objectWillChange.send()
            refreshMetering()
        }
    }

    private func refreshMetering() {
        guard shouldMeter else {
            levelMonitor.stop()
            return
        }
        levelMonitor.start(device: settings.selectedAudioDevice)
    }
}

struct OverlaysPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsForm {
            Section(SettingsText.windowFraming) {
                Toggle(SettingsText.frameWindowRecordings, isOn: $settings.frameWindowRecordings)

                if settings.frameWindowRecordings {
                    LabeledContent(SettingsText.windowBackgroundLabel) {
                        HStack(spacing: 8) {
                            ForEach(AppSettings.WindowBackground.allCases, id: \.self) { background in
                                BackgroundSwatch(
                                    background: background,
                                    isSelected: settings.windowBackground == background,
                                    onSelect: { settings.windowBackground = background }
                                )
                            }
                        }
                    }
                }
            }

            Section(SettingsText.textOverlay) {
                Toggle(SettingsText.addTextOverlay, isOn: $settings.textOverlayEnabled)

                if settings.textOverlayEnabled {
                    TextField(SettingsText.text, text: $settings.textOverlayText, prompt: Text(SettingsText.textPrompt))

                    Picker(SettingsText.position, selection: $settings.textOverlayPosition) {
                        ForEach(AppSettings.TextOverlayPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                }
            }
        }
    }
}

/// A background shown as itself, painted from the same fill the compositor
/// draws behind framed windows.
private struct BackgroundSwatch: View {
    let background: AppSettings.WindowBackground
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            RoundedRectangle(cornerRadius: 5)
                .fill(style)
                .frame(width: 30, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .help(background.displayName)
        .accessibilityLabel(background.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var style: AnyShapeStyle {
        switch background.fill {
        case .solid(let color):
            return AnyShapeStyle(Self.color(color))
        case .linearGradient(let from, let to):
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Self.color(from), Self.color(to)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                ))
        }
    }

    private static func color(_ color: CIColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var recordingAction: HotkeyAction?

    var body: some View {
        SettingsForm {
            Section {
                ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                    ShortcutRow(
                        action: action,
                        combo: settings.hotkey(for: action),
                        isRecording: recordingAction == action,
                        onBeginRecording: { recordingAction = action },
                        onRecorded: { combo in
                            settings.setHotkey(combo, for: action)
                            recordingAction = nil
                        },
                        onCancel: { recordingAction = nil },
                        onTurnOff: {
                            settings.setHotkey(nil, for: action)
                            recordingAction = nil
                        }
                    )
                }

                if let error = settings.hotkeyError {
                    CaptionText(error, color: .red)
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    CaptionText(SettingsText.shortcutHelp)
                    Spacer()
                    Button(SettingsText.restoreDefaultShortcuts) {
                        settings.resetHotkeys()
                    }
                    .disabled(settings.usesDefaultHotkeys)
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    let action: HotkeyAction
    let combo: AppSettings.HotkeyCombo?
    let isRecording: Bool
    let onBeginRecording: () -> Void
    let onRecorded: (AppSettings.HotkeyCombo) -> Void
    let onCancel: () -> Void
    let onTurnOff: () -> Void

    private var canTurnOff: Bool {
        combo != nil && !isRecording
    }

    var body: some View {
        LabeledContent(action.displayName) {
            HStack(spacing: 6) {
                Button(action: onBeginRecording) {
                    Text(label)
                        .foregroundStyle(combo == nil && !isRecording ? .secondary : .primary)
                        .frame(minWidth: 100)
                }
                .background(
                    HotkeyRecorder(
                        isRecording: isRecording,
                        onRecorded: onRecorded,
                        onCancel: onCancel
                    ))

                // Kept in the layout while hidden, so the shortcut buttons
                // stay aligned across rows.
                Button(action: onTurnOff) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(SettingsText.turnOffShortcut)
                .accessibilityLabel("\(SettingsText.turnOffShortcut), \(action.displayName)")
                .opacity(canTurnOff ? 1 : 0)
                .disabled(!canTurnOff)
                .accessibilityHidden(!canTurnOff)
            }
        }
    }

    private var label: String {
        if isRecording {
            return SettingsText.pressShortcut
        }
        return combo?.displayString ?? SettingsText.noShortcut
    }
}

struct HotkeyRecorder: NSViewRepresentable {
    let isRecording: Bool
    let onRecorded: (AppSettings.HotkeyCombo) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyRecorderView {
        HotkeyRecorderView()
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        nsView.onHotkeyRecorded = { keyCode, modifiers in
            onRecorded(AppSettings.HotkeyCombo(keyCode: keyCode, modifiers: modifiers))
        }
        nsView.onCancel = onCancel

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

        guard
            modifierFlags.contains(.command) || modifierFlags.contains(.control) || modifierFlags.contains(.option)
                || modifierFlags.contains(.shift)
        else {
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
            Task { @MainActor in
                HotkeyManager.shared.resume()
            }
        }
    }

    func startRecording() {
        guard monitor == nil else { return }
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            switch HotkeyRecorderLogic.decision(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            case .cancel:
                self?.stopRecording()
                self?.onCancel?()
                return nil
            case .record(let keyCode, let modifiers):
                // Restore the current shortcuts first, so the new one is
                // registered against them and conflicts are reported.
                self?.stopRecording()
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
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        HotkeyManager.shared.resume()
    }

    /// Closing Settings or switching tabs mid-capture must not leave the
    /// global shortcuts suspended.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopRecording()
        }
    }
}
