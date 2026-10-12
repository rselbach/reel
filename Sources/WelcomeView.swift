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
    static let relaunchNote =
        "After granting access in System Settings, macOS requires relaunching Reel before recording works."
    static let getStarted = "Get Started"
}

enum WelcomeLogic {
    static func canOfferRelaunch(
        isBundledApp: Bool,
        hasRequestedPermission: Bool,
        hasPermission: Bool
    ) -> Bool {
        isBundledApp && hasRequestedPermission && !hasPermission
    }
}

/// One-time window shown on first launch. Menu bar apps otherwise appear to
/// do nothing when opened, and the screen-recording permission prompt fires
/// with no context; this explains both before anything is requested.
struct WelcomeView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var settings = AppSettings.shared
    let onRequestPermission: () -> Void
    let onDismiss: () -> Void
    @State private var relaunchError: String?
    @State private var hasRequestedPermission = false

    private var canRelaunch: Bool {
        WelcomeLogic.canOfferRelaunch(
            isBundledApp: AppRelauncher.isAvailable,
            hasRequestedPermission: hasRequestedPermission,
            hasPermission: recorder.hasPermission
        )
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

            if recorder.hasPermission {
                Label(WelcomeText.permissionGranted, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 8) {
                    Text(WelcomeText.permissionExplainer)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(WelcomeText.grantPermission) {
                        hasRequestedPermission = true
                        onRequestPermission()
                    }

                    if hasRequestedPermission {
                        Text(WelcomeText.relaunchNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        if canRelaunch {
                            Button(PermissionText.relaunch) {
                                relaunch()
                            }
                        }
                    }
                }
            }

            Button(WelcomeText.getStarted) {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 440)
        .alert(
            PermissionText.relaunchFailedTitle,
            isPresented: Binding(
                get: { relaunchError != nil },
                set: { if !$0 { relaunchError = nil } }
            )
        ) {
            Button("OK") { relaunchError = nil }
        } message: {
            Text(relaunchError ?? "")
        }
    }

    private func relaunch() {
        Task { @MainActor in
            do {
                try await AppRelauncher.relaunch()
            } catch {
                relaunchError = error.localizedDescription
            }
        }
    }
}
