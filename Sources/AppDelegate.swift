import AppKit
import os.log
import Sparkle
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var screenRecorder: ScreenRecorder!
    private var settingsWindow: NSWindow?
    private var recordingDialogWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var isCountdownActive = false
    private var hotkeyObserver: NSObjectProtocol?
    private var cameraOverlayController: CameraOverlayController?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = hotkeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        screenRecorder = ScreenRecorder()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Reel")
        }

        AppSettings.shared.checkLaunchAtLoginStatus()
        setupHotkey()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.hotkeyChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
            }
        }

        Task { @MainActor in
            await screenRecorder.requestPermission()
            rebuildMenu()
        }
    }

    private func setupHotkey() {
        HotkeyManager.shared.onToggleRecording = { [weak self] in
            self?.handleToggleRecording()
        }

        HotkeyManager.shared.onHotkeyDisabled = { [weak self] message in
            self?.showHotkeyDisabledAlert(message: message)
        }

        if HotkeyManager.shared.hasAccessibilityPermission() {
            HotkeyManager.shared.start()
        }
    }

    private func handleToggleRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.screenRecorder.isRecording {
                await self.stopRecordingFlow()
            } else {
                // Check permission and available displays before starting
                guard self.screenRecorder.hasPermission,
                      !self.screenRecorder.availableDisplays.isEmpty else {
                    // Show dialog if no permission or no displays available
                    self.showRecordingDialog()
                    return
                }
                // Prevent multiple overlapping countdowns
                guard !self.isCountdownActive else { return }
                self.isCountdownActive = true

                // Show countdown before starting (same as menu flow)
                let shouldStart = await CountdownOverlay().show(targetFrame: self.screenRecorder.countdownTargetFrame)
                self.isCountdownActive = false
                guard shouldStart else { return }
                await self.screenRecorder.startRecording()
                self.showCameraOverlayIfNeeded()
                self.rebuildMenu()
            }
        }
    }

    private func showHotkeyDisabledAlert(message: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Hotkey Error"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        addPermissionOrRecordingItems(to: menu)
        addAccessibilityItems(to: menu)
        addErrorItems(to: menu)
        addStandardItems(to: menu)

        statusItem.menu = menu
    }

    private func addPermissionOrRecordingItems(to menu: NSMenu) {
        guard screenRecorder.hasPermission else {
            addPermissionItems(to: menu)
            return
        }
        addRecordingItems(to: menu)
    }

    private func addPermissionItems(to menu: NSMenu) {
        let permItem = NSMenuItem(title: "Screen Recording Permission Required", action: nil, keyEquivalent: "")
        permItem.isEnabled = false
        menu.addItem(permItem)

        menu.addItem(NSMenuItem(title: "Open System Settings...", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check Permission", action: #selector(checkPermission), keyEquivalent: ""))
    }

    private func addRecordingItems(to menu: NSMenu) {
        guard screenRecorder.isRecording else {
            menu.addItem(NSMenuItem(title: "Start Recording...", action: #selector(showRecordingDialog), keyEquivalent: "r"))
            return
        }
        let recordingItem = NSMenuItem(title: "● Recording...", action: nil, keyEquivalent: "")
        recordingItem.isEnabled = false
        menu.addItem(recordingItem)
        menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "s"))
    }

    private func addAccessibilityItems(to menu: NSMenu) {
        if !HotkeyManager.shared.hasAccessibilityPermission() {
            menu.addItem(NSMenuItem.separator())
            let accessItem = NSMenuItem(title: "Enable Keyboard Shortcuts...", action: #selector(requestAccessibility), keyEquivalent: "")
            menu.addItem(accessItem)
        }
    }

    private func addErrorItems(to menu: NSMenu) {
        if let error = screenRecorder.errorMessage {
            menu.addItem(NSMenuItem.separator())
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }
        if let launchError = AppSettings.shared.launchAtLoginError {
            menu.addItem(NSMenuItem.separator())
            let launchErrorItem = NSMenuItem(title: launchError, action: nil, keyEquivalent: "")
            launchErrorItem.isEnabled = false
            menu.addItem(launchErrorItem)
        }
    }

    private func addStandardItems(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About Reel", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeWindow<Content: View>(
        title: String,
        styleMask: NSWindow.StyleMask,
        rootView: Content
    ) -> NSWindow {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.styleMask = styleMask
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }

    private func presentWindow(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            aboutWindow = makeWindow(
                title: "About Reel",
                styleMask: [.titled, .closable],
                rootView: AboutView()
            )
        }

        presentWindow(aboutWindow)
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            logger.error("Failed to create System Settings URL for screen capture privacy settings")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkPermission() {
        Task { @MainActor in
            await screenRecorder.requestPermission()
            rebuildMenu()
        }
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            await stopRecordingFlow()
        }
    }

    private func stopRecordingFlow() async {
        hideCameraOverlay()
        await screenRecorder.stopRecording()
        rebuildMenu()
        if AppSettings.shared.showPreviewAfterRecording,
           let url = screenRecorder.lastRecordedURL {
            showPreview(for: url)
        }
    }

    private func showPreview(for url: URL) {
        let previewView = PostRecordingView(
            videoURL: url,
            onDismiss: { [weak self] in
                self?.previewWindow?.close()
                self?.previewWindow = nil
            },
            onRevealInFinder: {
                NSWorkspace.shared.selectFile(url.path(), inFileViewerRootedAtPath: "")
            },
            onDelete: { [weak self] in
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Could not delete recording"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                self?.previewWindow?.close()
                self?.previewWindow = nil
            }
        )

        previewWindow = makeWindow(
            title: "Recording Preview",
            styleMask: [.titled, .closable, .resizable],
            rootView: previewView
        )
        presentWindow(previewWindow)
    }

    @objc private func showRecordingDialog() {
        if recordingDialogWindow != nil {
            recordingDialogWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        Task { @MainActor in
            await screenRecorder.refreshWindows()
            
            let dialogView = RecordingDialog(
                availableDisplays: screenRecorder.availableDisplays,
                availableWindows: screenRecorder.availableWindows,
                onStart: { [weak self] selection in
                    guard let self else { return }
                    self.recordingDialogWindow?.close()
                    self.recordingDialogWindow = nil
                    self.startRecording(selection: selection)
                },
                onCancel: { [weak self] in
                    self?.recordingDialogWindow?.close()
                    self?.recordingDialogWindow = nil
                }
            )

            recordingDialogWindow = makeWindow(
                title: "New Recording",
                styleMask: [.titled, .closable],
                rootView: dialogView
            )
            presentWindow(recordingDialogWindow)
        }
    }
    
    private func startRecording(selection: RecordingSelection) {
        Task { @MainActor in
            switch selection {
            case .display(let index):
                screenRecorder.selectedDisplayIndex = index
                screenRecorder.recordingMode = .display
            case .window(let window):
                screenRecorder.selectedWindow = window
                screenRecorder.recordingMode = .window
            }
            
            guard await CountdownOverlay().show(targetFrame: screenRecorder.countdownTargetFrame) else { return }
            await screenRecorder.startRecording()
            showCameraOverlayIfNeeded()
            rebuildMenu()
        }
    }
    
    /// Shows the draggable camera overlay if camera recording is enabled.
    private func showCameraOverlayIfNeeded() {
        let settings = AppSettings.shared
        guard settings.recordCamera,
              let session = screenRecorder.activeCameraCaptureSession,
              let bounds = screenRecorder.recordingBounds else {
            return
        }
        
        cameraOverlayController = CameraOverlayController()
        cameraOverlayController?.show(
            session: session,
            bounds: bounds,
            initialPosition: settings.cameraPosition,
            size: settings.cameraSize,
            shape: settings.cameraShape,
            onPositionChanged: { [weak self] x, y in
                self?.screenRecorder.updateCameraOverlayPosition(x: x, y: y)
            }
        )
    }
    
    /// Hides the camera overlay window.
    private func hideCameraOverlay() {
        cameraOverlayController?.hide()
        cameraOverlayController = nil
    }

    @objc private func requestAccessibility() {
        HotkeyManager.shared.requestAccessibilityPermission()

        // Poll for permission with timeout instead of fixed delay
        Task { @MainActor in
            let maxAttempts = 60  // 30 seconds at 0.5s intervals
            for _ in 0..<maxAttempts {
                try? await Task.sleep(for: .milliseconds(500))
                if HotkeyManager.shared.hasAccessibilityPermission() {
                    HotkeyManager.shared.start()
                    rebuildMenu()
                    return
                }
            }
            // Timeout reached, update menu anyway to reflect current state
            rebuildMenu()
        }
    }

    @objc private func openPreferences() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "Reel Settings",
                styleMask: [.titled, .closable],
                rootView: SettingsView()
            )
        }

        presentWindow(settingsWindow)
    }

    func updateIcon(isRecording: Bool) {
        if let button = statusItem.button {
            let symbolName = isRecording ? "record.circle.fill" : "record.circle"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Reel")
            button.contentTintColor = isRecording ? .red : nil
        }
        rebuildMenu()
    }
}
