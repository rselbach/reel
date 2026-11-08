import AppKit
import SwiftUI

enum WelcomeText {
    static let windowTitle = "Welcome to Reel"
    static let title = "Welcome to Reel"
    static let menuBarExplainer =
        "Reel lives in your menu bar — look for the record icon near your clock. Click it to choose what to record; while recording, click it to stop."
    static let hotkeyPrefix = "Or toggle recording from anywhere with"
    static let getStarted = "Get Started"
}

/// The window shown on first launch and whenever screen recording is not in
/// effect. Menu bar apps otherwise appear to do nothing when opened, and
/// macOS's permission prompts give no context; this explains both and lists
/// each permission with a way to grant it.
struct WelcomeView: View {
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var settings = AppSettings.shared
    let onGrant: (PrivacyPermission) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // System Settings takes Reel into its screen recording list from
            // a drag of this icon.
            DraggableAppIcon()
                .frame(width: 96, height: 96)

            Text(WelcomeText.title)
                .font(.title)
                .fontWeight(.bold)

            Text(WelcomeText.menuBarExplainer)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let hotkey = settings.recordingHotkey {
                HStack(spacing: 6) {
                    Text(WelcomeText.hotkeyPrefix)
                        .foregroundStyle(.secondary)
                    Text(hotkey.displayString)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
            }

            permissionList

            getStartedButton
                .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 480)
    }

    private var permissionList: some View {
        VStack(spacing: 0) {
            ForEach(PrivacyPermission.allCases) { permission in
                if permission != PrivacyPermission.allCases.first {
                    Divider()
                        .padding(.leading, 52)
                }
                PermissionRow(
                    permission: permission,
                    state: permissions.state(of: permission),
                    isGuiding: permissions.guiding == permission,
                    onGrant: { onGrant(permission) }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    /// Skipping setup stays possible, but it is the default only once
    /// recording can actually work.
    @ViewBuilder
    private var getStartedButton: some View {
        if permissions.state(of: .screenRecording) == .granted {
            Button(WelcomeText.getStarted, action: onDismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(WelcomeText.getStarted, action: onDismiss)
        }
    }
}

private struct PermissionRow: View {
    let permission: PrivacyPermission
    let state: PermissionState
    let isGuiding: Bool
    let onGrant: () -> Void

    private var message: String {
        if state == .needsRelaunch {
            return PermissionText.relaunchHint
        }
        guard isGuiding else { return permission.detail }
        return permission.acceptsDroppedApp ? PermissionText.dragHint : PermissionText.toggleHint
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isGuiding ? Color.accentColor : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .granted:
            Label(PermissionText.granted, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.12)))
        case .notRequested, .missing:
            Button(PermissionText.grant, action: onGrant)
        case .needsRelaunch:
            Button(PermissionText.relaunchShort, action: onGrant)
                .buttonStyle(.borderedProminent)
        }
    }
}
