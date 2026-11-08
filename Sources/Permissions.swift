import AppKit
import SwiftUI

/// Wording shared by every place that deals with a missing screen recording
/// permission, so the menu, the welcome window, and the picker agree.
enum PermissionText {
    static let required = "Screen Recording Permission Required"
    static let openSystemSettings = "Open System Settings..."
    static let relaunch = "Relaunch Reel"
    static let turnOnStep =
        "1. In System Settings → Privacy & Security → Screen & System Audio Recording, turn on Reel."
    static let relaunchStep = "2. Relaunch Reel. macOS applies the change only after Reel restarts."
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

/// The two steps out of a missing permission, shared by the welcome window
/// and the recording picker. Both buttons stay available because Reel
/// cannot tell whether the user has already turned access on: the grant
/// only becomes visible to Reel after a relaunch.
struct ScreenRecordingPermissionSteps: View {
    let onOpenSystemSettings: @MainActor () async throws -> Void

    @State private var failure: Failure?

    private struct Failure {
        let title: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(PermissionText.turnOnStep)
                Text(PermissionText.relaunchStep)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(PermissionText.openSystemSettings) {
                    Task { await run(onOpenSystemSettings, failureTitle: PermissionText.openSettingsFailedTitle) }
                }
                if AppRelauncher.isAvailable {
                    Button(PermissionText.relaunch) {
                        Task { await run(AppRelauncher.relaunch, failureTitle: PermissionText.relaunchFailedTitle) }
                    }
                }
            }
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            ),
            presenting: failure
        ) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private func run(_ action: @MainActor () async throws -> Void, failureTitle: String) async {
        do {
            try await action()
        } catch {
            failure = Failure(title: failureTitle, message: error.localizedDescription)
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
