import AppKit

/// Wording shared by every place that deals with a missing screen recording
/// permission, so the menu, the welcome window, and the picker agree.
enum PermissionText {
    static let required = "Screen Recording Permission Required"
    static let openSystemSettings = "Open System Settings..."
    static let relaunch = "Relaunch Reel"
    static let openSettingsFailedTitle = "Could not open System Settings"
    static let relaunchFailedTitle = "Could not relaunch Reel"
}

enum PermissionError: LocalizedError {
    case systemSettingsUnavailable

    var errorDescription: String? {
        switch self {
        case .systemSettingsUnavailable:
            return "Open System Settings, then go to Privacy & Security → Screen & System Audio Recording."
        }
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
