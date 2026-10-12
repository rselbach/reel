import AppKit
import SwiftUI

enum WelcomeText {
    static let windowTitle = "Welcome to Reel"
    static let title = "Welcome to Reel"
    static let menuBarExplainer =
        "Reel lives in your menu bar — look for the record icon near your clock. Click it to choose what to record; while recording, click it to stop."
    static let hotkeyPrefix = "Or toggle recording from anywhere with"
    static let permissionGranted = "Screen recording access granted"
    static let permissionExplainer = "Reel needs macOS screen recording permission to capture your screen."
    static let grantPermission = "Grant Screen Recording Access"
    static let getStarted = "Get Started"
}

/// Where first-run setup stands. Reel cannot see a grant until it relaunches,
/// so once access has been requested and is still not in effect, the window
/// switches to the steps that finish the job.
enum WelcomeStep: Equatable {
    case requestAccess
    case finishInSettings
    case ready

    static func current(hasPermission: Bool, hasRequestedPermission: Bool) -> WelcomeStep {
        if hasPermission {
            return .ready
        }
        return hasRequestedPermission ? .finishInSettings : .requestAccess
    }
}

/// One-time window shown on first launch. Menu bar apps otherwise appear to
/// do nothing when opened, and the screen-recording permission prompt fires
/// with no context; this explains both before anything is requested.
struct WelcomeView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var settings = AppSettings.shared
    let onRequestPermission: () -> Void
    let onOpenSystemSettings: @MainActor () async throws -> Void
    let onDismiss: () -> Void
    @State private var hasRequestedPermission = false

    private var step: WelcomeStep {
        .current(hasPermission: recorder.hasPermission, hasRequestedPermission: hasRequestedPermission)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text(WelcomeText.title)
                .font(.title)
                .fontWeight(.bold)

            Text(WelcomeText.menuBarExplainer)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(WelcomeText.hotkeyPrefix)
                    .foregroundStyle(.secondary)
                Text(settings.recordingHotkey.displayString)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }

            Divider()

            permissionSection

            getStartedButton
                .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 440)
    }

    @ViewBuilder
    private var permissionSection: some View {
        switch step {
        case .requestAccess:
            VStack(spacing: 8) {
                Text(WelcomeText.permissionExplainer)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button(WelcomeText.grantPermission) {
                    hasRequestedPermission = true
                    onRequestPermission()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        case .finishInSettings:
            ScreenRecordingPermissionSteps(onOpenSystemSettings: onOpenSystemSettings)
        case .ready:
            Label(WelcomeText.permissionGranted, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    /// Skipping setup stays possible, but it is the default only once
    /// recording can actually work.
    @ViewBuilder
    private var getStartedButton: some View {
        if step == .ready {
            Button(WelcomeText.getStarted, action: onDismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(WelcomeText.getStarted, action: onDismiss)
        }
    }
}
