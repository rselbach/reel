import AVFoundation
import AppKit

/// Wording shared by every place that deals with permissions, so the menu,
/// the welcome window, and the picker agree.
enum PermissionText {
    static let required = "Screen Recording Permission Required"
    static let pickerExplainer = "Reel needs screen recording access to show your displays and windows."
    static let grantAccess = "Grant Access..."
    static let grant = "Grant..."
    static let granted = "Granted"
    static let relaunch = "Relaunch Reel"
    static let relaunchShort = "Relaunch"
    static let dragHint = "Drag the Reel icon above into the list in System Settings, or turn on Reel if it's listed."
    static let toggleHint = "Turn on Reel in the list in System Settings."
    static let relaunchHint = "Allowed. Relaunch Reel to start recording."
    static let openSettingsFailedTitle = "Could not open System Settings"
    static let relaunchFailedTitle = "Could not relaunch Reel"
}

enum PermissionError: LocalizedError {
    case systemSettingsUnavailable(PrivacyPermission)

    var errorDescription: String? {
        switch self {
        case .systemSettingsUnavailable(let permission):
            return "Open System Settings, then go to Privacy & Security → \(permission.title)."
        }
    }
}

/// A macOS privacy permission Reel asks for.
///
/// Screen recording comes last: macOS may need Reel to relaunch before it
/// applies, which would interrupt granting the others.
enum PrivacyPermission: CaseIterable, Identifiable {
    case microphone
    case camera
    case screenRecording

    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: return "Screen & System Audio Recording"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return "Required to record your displays, windows, and the sound your Mac plays."
        case .microphone: return "Records your voice along with the screen."
        case .camera: return "Optional. Shows you in a bubble over the recording."
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .microphone: return "mic"
        case .camera: return "video"
        }
    }

    /// The Privacy & Security pane that lists Reel for this permission.
    var settingsURL: URL? {
        let anchor =
            switch self {
            case .screenRecording: "Privacy_ScreenCapture"
            case .microphone: "Privacy_Microphone"
            case .camera: "Privacy_Camera"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// The screen recording list takes apps dropped onto it. The microphone
    /// and camera lists show only apps that have already asked.
    var acceptsDroppedApp: Bool {
        self == .screenRecording
    }

    var mediaType: AVMediaType? {
        switch self {
        case .screenRecording: return nil
        case .microphone: return .audio
        case .camera: return .video
        }
    }
}

/// Where one permission stands, as far as the user needs to act on it.
enum PermissionState: Equatable {
    case granted
    /// macOS has not asked yet; requesting shows the system prompt.
    case notRequested
    /// Only System Settings can grant it now.
    case missing
    /// Allowed in System Settings, but macOS applies it only after Reel
    /// restarts.
    case needsRelaunch

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notRequested
        default: self = .missing
        }
    }

    /// Screen recording has no prompt worth using: macOS's own sends the
    /// user to System Settings anyway, so Reel goes there directly.
    static func screenRecording(inEffect: Bool, allowedInSettings: Bool) -> PermissionState {
        if inEffect {
            return .granted
        }
        return allowedInSettings ? .needsRelaunch : .missing
    }
}

/// Asks a fresh copy of Reel whether screen recording is allowed. A running
/// process keeps the answer macOS gave it, so only a new process sees a grant
/// the user just made in System Settings.
enum ScreenRecordingProbe {
    static let argument = "--probe-screen-recording"

    static func isAllowed() async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

/// Tracks every permission Reel uses while the welcome window is open. The
/// user changes them in System Settings, which tells Reel nothing, so the
/// center polls.
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var states: [PrivacyPermission: PermissionState] = [:]
    /// The permission the user is granting in System Settings right now.
    @Published private(set) var guiding: PrivacyPermission?
    /// Called after any state changes, so the menu can follow.
    var onChange: (() -> Void)?

    private let recorder: ScreenRecorder
    private let guide = SystemSettingsGuide()
    private var screenRecordingAllowed = false
    private var monitorTask: Task<Void, Never>?

    init(recorder: ScreenRecorder) {
        self.recorder = recorder
        states = [
            .screenRecording: .screenRecording(
                inEffect: recorder.hasPermission || CGPreflightScreenCaptureAccess(),
                allowedInSettings: false
            ),
            .microphone: PermissionState(AVCaptureDevice.authorizationStatus(for: .audio)),
            .camera: PermissionState(AVCaptureDevice.authorizationStatus(for: .video)),
        ]
    }

    func state(of permission: PrivacyPermission) -> PermissionState {
        states[permission] ?? .missing
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        endGuide()
    }

    /// Prompts for a permission macOS has not asked about, or walks the user
    /// through System Settings for one only it can grant.
    func grant(_ permission: PrivacyPermission, beside window: NSWindow?) async throws {
        switch state(of: permission) {
        case .notRequested:
            if let mediaType = permission.mediaType {
                _ = await AVCaptureDevice.requestAccess(for: mediaType)
            }
            await refresh()
        case .missing:
            guard let window else { return }
            guiding = permission
            try await guide.begin(permission, beside: window)
        case .granted, .needsRelaunch:
            break
        }
    }

    func refresh() async {
        if !recorder.hasPermission, !screenRecordingAllowed {
            let allowed = CGPreflightScreenCaptureAccess() ? true : await ScreenRecordingProbe.isAllowed()
            if allowed {
                screenRecordingAllowed = true
                // Asking ScreenCaptureKit now shows no prompt, and succeeds
                // when macOS applies the grant without a restart.
                await recorder.requestPermission()
            }
        }
        let next: [PrivacyPermission: PermissionState] = [
            .screenRecording: .screenRecording(
                inEffect: recorder.hasPermission,
                allowedInSettings: screenRecordingAllowed
            ),
            .microphone: PermissionState(AVCaptureDevice.authorizationStatus(for: .audio)),
            .camera: PermissionState(AVCaptureDevice.authorizationStatus(for: .video)),
        ]
        if let guiding, next[guiding] != .missing {
            endGuide()
        }
        guard next != states else { return }
        states = next
        onChange?()
    }

    private func endGuide() {
        guiding = nil
        guide.end()
    }
}

/// macOS applies a new screen recording grant only after Reel restarts.
@MainActor
enum AppRelauncher {
    /// Under `swift run` there is no app bundle for the workspace to reopen.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Starts a fresh instance, then quits this one. macOS refuses a second
    /// launch of the same bundle unless a new instance is requested
    /// explicitly.
    static func relaunch() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.terminate(nil)
    }
}
