import AppKit
import SwiftUI

enum WelcomeText {
    static let windowTitle = "Welcome to Reel"
    static let title = "Welcome to Reel"
    static let menuBarExplainer = "Reel lives in your menu bar — look for the record icon near your clock. Click it to start a recording, click it again to stop."
    static let hotkeyPrefix = "Or toggle recording from anywhere with"
    static let permissionGranted = "Screen recording access granted"
    static let permissionExplainer = "Reel needs macOS screen recording permission to capture your screen."
    static let grantPermission = "Grant Screen Recording Access"
    static let relaunchNote = "After granting access in System Settings, macOS requires relaunching Reel before recording works."
    static let getStarted = "Get Started"
}

/// One-time window shown on first launch. Menu bar apps otherwise appear to
/// do nothing when opened, and the screen-recording permission prompt fires
/// with no context; this explains both before anything is requested.
struct WelcomeView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var settings = AppSettings.shared
    let onRequestPermission: () -> Void
    let onDismiss: () -> Void

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

                    Button(WelcomeText.grantPermission) {
                        onRequestPermission()
                    }

                    Text(WelcomeText.relaunchNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
    }
}
