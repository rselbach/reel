import AppKit
import os.log
import Sparkle
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "AppDelegate")

enum SystemSettingsLink {
    static let screenCapturePrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
}

enum AppMenuText {
    static let screenRecordingPermissionRequired = "Screen Recording Permission Required"
    static let openSystemSettings = "Open System Settings..."
    static let checkPermission = "Check Permission"
    static let relaunchAfterGranting = "Relaunch Reel after granting permission"
    static let startRecording = "Start Recording..."
    static let recordingInProgress = "● Recording..."
    static let stopRecording = "Stop Recording"
    static let aboutReel = "About Reel"
    static let checkForUpdates = "Check for Updates..."
    static let settings = "Settings..."
    static let quitReel = "Quit Reel"
    static let openRecordingsFolder = "Open Recordings Folder"
    static let recentRecordings = "Recent Recordings"
    static let couldNotOpenRecording = "Could not open recording"
    static let couldNotOpenRecordingsFolder = "Could not open recordings folder"
    static let hotkeyError = "Hotkey Error"
    static let recordingFailed = "Recording Failed"
    static let recordingWarning = "Recording Warning"
    static let recordingStopped = "Recording Stopped"
    static let unableToOpenSettings = "Unable to open settings"
    static let failedToOpenPrivacySettings = "Failed to open system privacy settings."
    static let couldNotOpenSystemPreferences = "Could not open System Preferences."
    static let couldNotRevealRecording = "Could not reveal recording"
    static let couldNotDeleteRecording = "Could not delete recording"
    static let recordingPreviewTitle = "Recording Preview"
    static let newRecordingTitle = "New Recording"
    static let settingsWindowTitle = "Reel Settings"
}

enum StatusItemClickLogic {
    /// Left-click stops an active recording immediately (stop latency matters
    /// at the end of a take); right-click, or any click while idle, opens the
    /// menu.
    static func shouldStopRecording(isRecording: Bool, isRightClick: Bool) -> Bool {
        isRecording && !isRightClick
    }
}

enum RecordingElapsedFormat {
    static func string(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let mins = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

enum AppTerminationLogic {
    static func reply(isRecorderInitialized: Bool, isRecording: Bool) -> NSApplication.TerminateReply {
        guard isRecorderInitialized else { return .terminateNow }
        return isRecording ? .terminateLater : .terminateNow
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var screenRecorder: ScreenRecorder!
    private var settingsWindow: NSWindow?
    private var recordingDialogWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var isCountdownActive = false
    private var activeCountdown: CountdownOverlay?
    private var hotkeyObserver: NSObjectProtocol?
    private var cameraOverlayController: CameraOverlayController?
    private var regionIndicatorController: RegionIndicatorController?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var statusMenu: NSMenu?
    private var windowTrackingTimer: Timer?
    // Sparkle needs a real app bundle; under `swift run` there is no
    // Info.plist and starting the updater misbehaves, so it stays nil in
    // unbundled dev builds.
    private var updaterController: SPUStandardUpdaterController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = AppTerminationLogic.reply(
            isRecorderInitialized: screenRecorder != nil,
            isRecording: screenRecorder?.isRecording ?? false
        )
        guard reply == .terminateLater else { return reply }

        // Finalize the in-flight recording before quitting so it isn't lost.
        Task { @MainActor in
            hideCameraOverlay()
            await screenRecorder.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = hotkeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        HotkeyManager.shared.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        screenRecorder = ScreenRecorder()
        screenRecorder.onUnexpectedStop = { [weak self] in
            self?.handleUnexpectedStop()
        }

        if Bundle.main.bundleIdentifier != nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Reel")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        if AppSettings.shared.hasShownWelcome {
            Task { @MainActor in
                await screenRecorder.requestPermission()
                rebuildMenu()
            }
        } else {
            // First launch: explain the menu bar icon and ask for the screen
            // recording permission with context instead of firing the TCC
            // prompt out of nowhere.
            rebuildMenu()
            showWelcome()
        }
    }

    private func showWelcome() {
        if welcomeWindow == nil {
            let welcomeView = WelcomeView(
                recorder: screenRecorder,
                onRequestPermission: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        await self.screenRecorder.requestPermission()
                        self.rebuildMenu()
                    }
                },
                onDismiss: { [weak self] in
                    self?.welcomeWindow?.close()
                }
            )
            welcomeWindow = makeWindow(
                title: WelcomeText.windowTitle,
                styleMask: [.titled, .closable],
                rootView: welcomeView
            )
        }

        presentWindow(welcomeWindow)
    }

    private func setupHotkey() {
        HotkeyManager.shared.onToggleRecording = { [weak self] in
            self?.handleToggleRecording()
        }

        HotkeyManager.shared.onHotkeyDisabled = { [weak self] message in
            self?.showHotkeyDisabledAlert(message: message)
        }

        HotkeyManager.shared.start()
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
                // Fall back to the picker when the remembered selection no
                // longer exists (window closed, display unplugged).
                guard await self.screenRecorder.validateSelectionForQuickStart() else {
                    self.showRecordingDialog()
                    return
                }
                // Pressing the hotkey again during the countdown cancels it
                if self.isCountdownActive {
                    self.activeCountdown?.cancel()
                    return
                }

                guard await self.runCountdown() else { return }
                await self.screenRecorder.startRecording()
                self.showCameraOverlayIfNeeded()
                self.showRegionIndicatorIfNeeded()
                self.rebuildMenu()
                self.reportStartOutcome()
            }
        }
    }

    /// Surfaces start failures (and degraded starts, e.g. mic didn't come up)
    /// as alerts instead of leaving them buried in the status item menu.
    private func reportStartOutcome() {
        guard let message = screenRecorder.errorMessage else { return }
        let title = screenRecorder.isRecording
            ? AppMenuText.recordingWarning
            : AppMenuText.recordingFailed
        showErrorAlert(title: title, message: message)
    }

    private func handleUnexpectedStop() {
        rebuildMenu()
        if let message = screenRecorder.errorMessage {
            showErrorAlert(title: AppMenuText.recordingStopped, message: message)
        }
        if AppSettings.shared.showPreviewAfterRecording,
           let url = screenRecorder.lastRecordedURL {
            showPreview(for: url)
        }
    }

    private func showHotkeyDisabledAlert(message: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = AppMenuText.hotkeyError
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addPermissionOrRecordingItems(to: menu)
        addRecordingsAccessItems(to: menu)
        addErrorItems(to: menu)
        addStandardItems(to: menu)

        statusMenu = menu
    }

    /// The status item has no permanent menu so left-clicks can act directly
    /// (stop an active recording); the menu is attached only while shown.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if StatusItemClickLogic.shouldStopRecording(
            isRecording: screenRecorder.isRecording,
            isRightClick: isRightClick
        ) {
            stopRecording()
            return
        }

        rebuildMenu()
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func addPermissionOrRecordingItems(to menu: NSMenu) {
        guard screenRecorder.hasPermission else {
            addPermissionItems(to: menu)
            return
        }
        addRecordingItems(to: menu)
    }

    private func addPermissionItems(to menu: NSMenu) {
        let permItem = NSMenuItem(title: AppMenuText.screenRecordingPermissionRequired, action: nil, keyEquivalent: "")
        permItem.isEnabled = false
        menu.addItem(permItem)

        menu.addItem(NSMenuItem(title: AppMenuText.openSystemSettings, action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: AppMenuText.checkPermission, action: #selector(checkPermission), keyEquivalent: ""))

        let relaunchNote = NSMenuItem(title: AppMenuText.relaunchAfterGranting, action: nil, keyEquivalent: "")
        relaunchNote.isEnabled = false
        menu.addItem(relaunchNote)
    }

    private func addRecordingItems(to menu: NSMenu) {
        guard screenRecorder.isRecording else {
            menu.addItem(NSMenuItem(title: AppMenuText.startRecording, action: #selector(showRecordingDialog), keyEquivalent: "r"))
            return
        }
        let recordingItem = NSMenuItem(title: AppMenuText.recordingInProgress, action: nil, keyEquivalent: "")
        recordingItem.isEnabled = false
        menu.addItem(recordingItem)
        menu.addItem(NSMenuItem(title: AppMenuText.stopRecording, action: #selector(stopRecording), keyEquivalent: "s"))
    }

    private func addRecordingsAccessItems(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: AppMenuText.openRecordingsFolder, action: #selector(openRecordingsFolder), keyEquivalent: ""))

        let recents = AppSettings.shared.existingRecentRecordings
        guard !recents.isEmpty else { return }

        let submenu = NSMenu()
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentRecording(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: AppMenuText.recentRecordings, action: nil, keyEquivalent: "")
        menu.addItem(parent)
        menu.setSubmenu(submenu, for: parent)
    }

    @objc private func openRecordingsFolder() {
        let url = AppSettings.shared.outputDirectory
        if !NSWorkspace.shared.open(url) {
            showErrorAlert(
                title: AppMenuText.couldNotOpenRecordingsFolder,
                message: "Finder could not open \(url.path())."
            )
        }
    }

    @objc private func openRecentRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if !NSWorkspace.shared.open(url) {
            showErrorAlert(
                title: AppMenuText.couldNotOpenRecording,
                message: "Could not open \(url.path()). The file may have been moved or deleted."
            )
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
        menu.addItem(NSMenuItem(title: AppMenuText.aboutReel, action: #selector(showAbout), keyEquivalent: ""))
        if updaterController != nil {
            menu.addItem(NSMenuItem(title: AppMenuText.checkForUpdates, action: #selector(checkForUpdates), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: AppMenuText.settings, action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: AppMenuText.quitReel, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window === settingsWindow {
            settingsWindow = nil
        } else if window === recordingDialogWindow {
            recordingDialogWindow = nil
        } else if window === previewWindow {
            previewWindow = nil
        } else if window === aboutWindow {
            aboutWindow = nil
        } else if window === welcomeWindow {
            welcomeWindow = nil
            AppSettings.shared.hasShownWelcome = true
        }
    }

    private func presentWindow(_ window: NSWindow?) {
        guard let window else { return }

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
        }
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            aboutWindow = makeWindow(
                title: AppMenuText.aboutReel,
                styleMask: [.titled, .closable],
                rootView: AboutView()
            )
        }

        presentWindow(aboutWindow)
    }

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc private func openSettings() {
        guard let url = SystemSettingsLink.screenCapturePrivacy else {
            logger.error("Failed to create System Settings URL for screen capture privacy settings")
            showErrorAlert(title: AppMenuText.unableToOpenSettings, message: AppMenuText.failedToOpenPrivacySettings)
            return
        }
        let opened = NSWorkspace.shared.open(url)
        if !opened {
            showErrorAlert(title: AppMenuText.unableToOpenSettings, message: AppMenuText.couldNotOpenSystemPreferences)
        }
    }

    private func showErrorAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
                let revealed = NSWorkspace.shared.selectFile(url.path(), inFileViewerRootedAtPath: "")
                if !revealed {
                    let alert = NSAlert()
                    alert.messageText = AppMenuText.couldNotRevealRecording
                    alert.informativeText = "Finder could not reveal the recording at \(url.path())."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            },
            onDelete: { [weak self] in
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = AppMenuText.couldNotDeleteRecording
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
                self?.previewWindow?.close()
                self?.previewWindow = nil
            }
        )

        previewWindow = makeWindow(
            title: AppMenuText.recordingPreviewTitle,
            styleMask: [.titled, .closable, .resizable],
            rootView: previewView
        )
        presentWindow(previewWindow)
    }

    @objc private func showRecordingDialog() {
        if recordingDialogWindow != nil {
            presentWindow(recordingDialogWindow)
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
                },
                onRefresh: { [weak self] in
                    guard let self else { return ([], []) }
                    await self.screenRecorder.refreshWindows()
                    return (self.screenRecorder.availableDisplays, self.screenRecorder.availableWindows)
                }
            )

            recordingDialogWindow = makeWindow(
                title: AppMenuText.newRecordingTitle,
                styleMask: [.titled, .closable],
                rootView: dialogView
            )
            presentWindow(recordingDialogWindow)
        }
    }
    
    private func startRecording(selection: RecordingSelection) {
        Task { @MainActor in
            guard !isCountdownActive else { return }

            switch selection {
            case .display(let index):
                screenRecorder.selectedDisplayIndex = index
                screenRecorder.recordingMode = .display
            case .window(let window):
                screenRecorder.selectedWindow = window
                screenRecorder.recordingMode = .window
            case .region:
                guard let region = await RegionSelector().select() else { return }
                screenRecorder.selectedRegion = region
                screenRecorder.recordingMode = .region
            }

            guard await runCountdown() else { return }
            await screenRecorder.startRecording()
            showCameraOverlayIfNeeded()
            showRegionIndicatorIfNeeded()
            rebuildMenu()
            reportStartOutcome()
        }
    }
    
    /// Runs the pre-recording countdown (if enabled) and returns true when
    /// recording should start.
    private func runCountdown() async -> Bool {
        guard !isCountdownActive else { return false }
        isCountdownActive = true
        let countdown = CountdownOverlay()
        activeCountdown = countdown
        let shouldStart = await countdown.show(
            targetFrame: screenRecorder.countdownTargetFrame,
            duration: AppSettings.shared.countdownDuration
        )
        activeCountdown = nil
        isCountdownActive = false
        return shouldStart
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

        startWindowTrackingIfNeeded()
    }

    /// Hides the camera overlay window.
    private func hideCameraOverlay() {
        stopWindowTracking()
        cameraOverlayController?.hide()
        cameraOverlayController = nil
    }

    /// Window recordings follow the window wherever it goes, but the camera
    /// overlay's drag bounds were captured at start. Poll the recorded
    /// window's frame and move the overlay along with it.
    private func startWindowTrackingIfNeeded() {
        guard screenRecorder.recordingMode == .window,
              let windowID = screenRecorder.selectedWindow?.windowID else {
            return
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncOverlayToRecordedWindow(windowID: windowID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowTrackingTimer = timer
    }

    private func stopWindowTracking() {
        windowTrackingTimer?.invalidate()
        windowTrackingTimer = nil
    }

    private func syncOverlayToRecordedWindow(windowID: CGWindowID) {
        guard let controller = cameraOverlayController,
              let quartzBounds = Self.windowBounds(windowID: windowID),
              let cocoaBounds = cocoaRect(fromQuartz: quartzBounds) else {
            return
        }
        controller.updateBounds(cocoaBounds)
    }

    private static func windowBounds(windowID: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let boundsDict = infoList.first?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
            return nil
        }
        return bounds
    }

    /// Shows a border around the recorded region so the user can see exactly
    /// what area is being captured.
    private func showRegionIndicatorIfNeeded() {
        guard screenRecorder.isRecording,
              screenRecorder.recordingMode == .region,
              let frame = screenRecorder.countdownTargetFrame else {
            return
        }

        regionIndicatorController = RegionIndicatorController()
        regionIndicatorController?.show(globalQuartzFrame: frame)
    }

    private func hideRegionIndicator() {
        regionIndicatorController?.hide()
        regionIndicatorController = nil
    }

    @objc private func openPreferences() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: AppMenuText.settingsWindowTitle,
                styleMask: [.titled, .closable],
                rootView: SettingsView()
            )
        }

        presentWindow(settingsWindow)
    }

    func updateIcon(isRecording: Bool) {
        if !isRecording {
            hideCameraOverlay()
            hideRegionIndicator()
        }

        if let button = statusItem.button {
            let symbolName = isRecording ? "record.circle.fill" : "record.circle"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Reel")
            button.contentTintColor = isRecording ? .red : nil
            button.imagePosition = .imageLeft
            button.toolTip = isRecording
                ? "Reel — click to stop recording"
                : "Reel"
        }

        if isRecording {
            startRecordingTimer()
        } else {
            stopRecordingTimer()
        }
        rebuildMenu()
    }

    /// Shows elapsed time next to the status icon while recording, so the
    /// user can see at a glance that the recording is actually rolling.
    private func startRecordingTimer() {
        guard recordingTimer == nil else { return }
        recordingStartedAt = Date()
        updateElapsedTitle()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsedTitle()
            }
        }
        // .common keeps the title updating while the status menu is open.
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
        statusItem.button?.title = ""
    }

    private func updateElapsedTitle() {
        guard let start = recordingStartedAt, let button = statusItem.button else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        button.attributedTitle = NSAttributedString(
            string: " " + RecordingElapsedFormat.string(seconds: elapsed),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
        )
    }
}
