import AppKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "AppDelegate")

enum AppMenuText {
    static let startRecording = "Start Recording..."
    static let recordingInProgress = "● Recording..."
    static let stopRecording = "Stop Recording"
    static let discardRecording = "Discard Recording"
    static let pauseRecording = "Pause Recording"
    static let resumeRecording = "Resume Recording"
    static let recordingPaused = "❚❚ Paused"
    static let recordingToolTip = "Reel — click to stop recording"
    static let pausedToolTip = "Reel — paused, click to stop recording"
    static let discardConfirmationTitle = "Discard this recording?"
    static let discardConfirmationMessage = "The take will be moved to the Trash."
    static let discard = "Discard"
    static let cancel = "Cancel"
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
    static let couldNotRevealRecording = "Could not reveal recording"
    static let couldNotDeleteRecording = "Could not move recording to Trash"
    static let newRecordingTitle = "New Recording"
    static let settingsWindowTitle = "Reel Settings"
}

enum MainMenuText {
    static let hideReel = "Hide Reel"
    static let hideOthers = "Hide Others"
    static let showAll = "Show All"
    static let edit = "Edit"
    static let undo = "Undo"
    static let redo = "Redo"
    static let cut = "Cut"
    static let copy = "Copy"
    static let paste = "Paste"
    static let selectAll = "Select All"
    static let window = "Window"
    static let minimize = "Minimize"
    static let zoom = "Zoom"
    static let bringAllToFront = "Bring All to Front"
    static let close = "Close"
}

enum PreviewPlacement {
    static let cascadeOffset: CGFloat = 24

    /// Places a new preview down and to the right of the last one, so a
    /// second preview never lands exactly on top of the first. Keeps the
    /// frame it was given when the step would leave the screen.
    static func cascadedFrame(_ frame: CGRect, after previous: CGRect, within visibleFrame: CGRect) -> CGRect {
        let cascaded = CGRect(
            x: previous.minX + cascadeOffset,
            y: previous.maxY - cascadeOffset - frame.height,
            width: frame.width,
            height: frame.height
        )
        return visibleFrame.contains(cascaded) ? cascaded : frame
    }
}

/// A preview's window. The Edit menu's Undo and Redo travel the responder
/// chain to the window, which answers them from the preview's own history
/// instead of from its empty undo manager.
final class PreviewWindow: NSWindow {
    var undoCommands = PreviewUndoCommands()
    var shareSource = PreviewShareSource()
    /// Kept while a drag is in flight; a file promise holds its delegate
    /// weakly.
    private var promisedRecording: PromisedRecording?

    /// Drags edits that are not rendered yet as a file promise, which
    /// Finder and Mail fill in once the render finishes.
    func beginPromisedFileDrag(with event: NSEvent) {
        guard let view = contentView else { return }
        let promise = PromisedRecording(source: shareSource)
        promisedRecording = promise
        let provider = NSFilePromiseProvider(fileType: UTType.mpeg4Movie.identifier, delegate: promise)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let point = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
            contents: NSWorkspace.shared.icon(for: .mpeg4Movie)
        )
        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    @objc func undo(_ sender: Any?) {
        undoCommands.undo()
    }

    @objc func redo(_ sender: Any?) {
        undoCommands.redo()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return undoCommands.canUndo()
        case #selector(redo(_:)):
            return undoCommands.canRedo()
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}

extension PreviewWindow: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}

/// Writes the preview's shareable file where a promised drag was dropped.
final class PromisedRecording: NSObject, NSFilePromiseProviderDelegate {
    private let source: PreviewShareSource
    private let fileName: String

    @MainActor
    init(source: PreviewShareSource) {
        self.source = source
        fileName = source.fileName()
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        nonisolated(unsafe) let completion = completionHandler
        let source = source
        Task { @MainActor in
            do {
                let file = try await source.shareableFile()
                try FileManager.default.copyItem(at: file, to: url)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}

enum StatusItemClickLogic {
    /// Left-click stops an active recording immediately (stop latency matters
    /// at the end of a take); right-click, or any click while idle, opens the
    /// menu.
    static func shouldStopRecording(isRecording: Bool, isRightClick: Bool) -> Bool {
        isRecording && !isRightClick
    }
}

enum RecordingToggleLogic {
    enum Action: Equatable {
        case start
        case cancelPendingStart
        case stop
    }

    static func action(isRecording: Bool, hasPendingStart: Bool) -> Action {
        if isRecording {
            return .stop
        }
        return hasPendingStart ? .cancelPendingStart : .start
    }
}

/// A global shortcut as a menu key equivalent, so the status menu shows the
/// combination that works from anywhere instead of one that works only
/// while the menu is open.
struct MenuShortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    private static let functionKeys: [UInt16] = [
        KeyCode.f1, KeyCode.f2, KeyCode.f3, KeyCode.f4, KeyCode.f5, KeyCode.f6,
        KeyCode.f7, KeyCode.f8, KeyCode.f9, KeyCode.f10, KeyCode.f11, KeyCode.f12,
    ]

    private static let specialKeys: [UInt16: Int] = [
        KeyCode.space: 0x20,
        KeyCode.return: 0x0D,
        KeyCode.tab: 0x09,
        KeyCode.delete: NSBackspaceCharacter,
        KeyCode.forwardDelete: NSDeleteFunctionKey,
        KeyCode.escape: 0x1B,
    ]

    init?(_ combo: AppSettings.HotkeyCombo) {
        guard let key = Self.key(for: combo.keyCode) else { return nil }
        self.key = key
        modifiers = NSEvent.ModifierFlags(rawValue: UInt(combo.modifiers))
            .intersection([.command, .option, .control, .shift])
    }

    private static func key(for keyCode: UInt16) -> String? {
        if let index = functionKeys.firstIndex(of: keyCode) {
            return character(NSF1FunctionKey + index)
        }
        if let code = specialKeys[keyCode] {
            return character(code)
        }
        // Menus take the unshifted character and draw it uppercase.
        return AppSettings.HotkeyCombo.keyCodeNames[keyCode]?.lowercased()
    }

    private static func character(_ code: Int) -> String? {
        UnicodeScalar(code).map { String(Character($0)) }
    }
}

enum QuickRecordTitle {
    static let prefix = "Record "

    /// The menu item that records what the toggle shortcut is pointed at,
    /// without the picker. Returns nil when nothing is selected yet, in which
    /// case the shortcut opens the picker instead.
    static func text(
        mode: RecordingMode,
        displayLabel: String?,
        windowLabel: String?,
        regionOutputSize: CGSize?
    ) -> String? {
        switch mode {
        case .display:
            return displayLabel.map { prefix + $0 }
        case .window:
            return windowLabel.map { prefix + $0 }
        case .region:
            guard let regionOutputSize else { return nil }
            let width = Int(regionOutputSize.width.rounded())
            let height = Int(regionOutputSize.height.rounded())
            return "\(prefix)Area (\(width) × \(height) px)"
        }
    }
}

/// What the status item shows. A paused take gets its own symbol and color,
/// so a forgotten pause does not pass for a live recording.
enum StatusItemState: Equatable {
    case idle
    case recording
    case paused

    init(isRecording: Bool, isPaused: Bool) {
        switch (isRecording, isPaused) {
        case (false, _): self = .idle
        case (true, false): self = .recording
        case (true, true): self = .paused
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "record.circle"
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    var tint: NSColor? {
        switch self {
        case .idle: return nil
        case .recording: return .red
        case .paused: return .systemOrange
        }
    }
}

/// Short system sounds confirming a take started or ended, for when the menu
/// bar is not being watched.
enum RecordingCue {
    case start
    case stop

    var soundName: String {
        switch self {
        case .start: return "Tink"
        case .stop: return "Bottle"
        }
    }

    @MainActor
    func play() {
        guard AppSettings.shared.playSoundCues else { return }
        guard let sound = NSSound(named: soundName) else {
            logger.warning("Missing system sound for recording cue: \(soundName, privacy: .public)")
            return
        }
        sound.play()
    }
}

enum WindowTracking {
    /// The recorded window's frame is polled rather than observed. At 1 Hz the
    /// camera overlay and capture border visibly lagged behind a window being
    /// dragged; CGWindowListCopyWindowInfo for a single window is cheap enough
    /// to run at something closer to UI rates.
    static let interval: TimeInterval = 1.0 / 15
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

enum LaunchLogic {
    /// The welcome explains the menu bar icon and asks for screen recording
    /// with context. It comes back on every launch until access is granted,
    /// instead of Reel firing the bare system prompt.
    static func showsWelcome(hasShownWelcome: Bool, hasScreenRecordingAccess: Bool) -> Bool {
        !hasShownWelcome || !hasScreenRecordingAccess
    }
}

enum AppTerminationLogic {
    static func reply(
        isRecorderInitialized: Bool,
        isRecording: Bool,
        isStarting: Bool
    ) -> NSApplication.TerminateReply {
        guard isRecorderInitialized else { return .terminateNow }
        return isRecording || isStarting ? .terminateLater : .terminateNow
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var screenRecorder: ScreenRecorder!
    private var settingsWindow: NSWindow?
    private var recordingDialogWindow: NSWindow?
    /// Every open preview. A recording can finish while an earlier
    /// preview is still open, so there can be more than one.
    private var previewWindows: [NSWindow] = []
    private var aboutWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var permissionCenter: PermissionCenter!
    private var isCountdownActive = false
    private var activeCountdown: CountdownOverlay?
    private var recordingStartTask: Task<Void, Never>?
    private var isPresentingRecordingDialog = false
    private var hotkeyObserver: NSObjectProtocol?
    private var cameraOverlayController: CameraOverlayController?
    private var captureBoundsIndicator: CaptureBoundsIndicator?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    /// Time spent paused, excluded from the elapsed readout so it reflects
    /// what is actually in the file.
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var statusMenu: NSMenu?
    private var windowTrackingTimer: Timer?
    // Sparkle needs a real app bundle; under `swift run` there is no
    // Info.plist and starting the updater misbehaves, so it stays nil in
    // unbundled dev builds.
    private var updaterController: SPUStandardUpdaterController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = AppTerminationLogic.reply(
            isRecorderInitialized: screenRecorder != nil,
            isRecording: screenRecorder?.isRecording ?? false,
            isStarting: screenRecorder?.isStarting ?? false
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
        screenRecorder.onRecordingStateChanged = { [weak self] isRecording in
            self?.updateIcon(isRecording: isRecording)
        }
        screenRecorder.onPauseStateChanged = { [weak self] isPaused in
            self?.updatePauseState(isPaused)
        }
        screenRecorder.requestSaveDestination = { [weak self] request in
            await self?.promptForSaveDestination(request)
        }
        permissionCenter = PermissionCenter(recorder: screenRecorder)
        permissionCenter.onChange = { [weak self] in
            self?.rebuildMenu()
            self?.applyStatusItemAppearance()
        }

        if Bundle.main.bundleIdentifier != nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }

        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        applyStatusItemAppearance()

        AppSettings.shared.checkLaunchAtLoginStatus()
        setupHotkey()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.hotkeyChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
                self?.applyStatusItemAppearance()
            }
        }

        // Checked without prompting: asking ScreenCaptureKit for content
        // would show the bare system prompt on every launch.
        if LaunchLogic.showsWelcome(
            hasShownWelcome: AppSettings.shared.hasShownWelcome,
            hasScreenRecordingAccess: CGPreflightScreenCaptureAccess()
        ) {
            rebuildMenu()
            showWelcome()
        } else {
            Task { @MainActor in
                await screenRecorder.requestPermission()
                screenRecorder.restoreRememberedTarget()
                rebuildMenu()
                applyStatusItemAppearance()
            }
        }
    }

    /// Reel never shows a menu bar of its own, but AppKit still routes key
    /// equivalents through the main menu. Without one, ⌘C, ⌘V, ⌘A, ⌘Z, and ⌘W
    /// do nothing in Reel's windows.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: AppMenuText.aboutReel, action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: AppMenuText.settings, action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: MainMenuText.hideReel, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: MainMenuText.hideOthers,
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: MainMenuText.showAll,
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: AppMenuText.quitReel, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: MainMenuText.edit)
        editMenu.addItem(withTitle: MainMenuText.undo, action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: MainMenuText.redo, action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: MainMenuText.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: MainMenuText.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: MainMenuText.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: MainMenuText.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: MainMenuText.window)
        windowMenu.addItem(
            withTitle: MainMenuText.minimize, action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: MainMenuText.zoom, action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(
            withTitle: MainMenuText.close, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: MainMenuText.bringAllToFront,
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        // AppKit lists Reel's open windows at the end of this menu.
        NSApp.windowsMenu = windowMenu
    }

    private func showWelcome() {
        if welcomeWindow == nil {
            let welcomeView = WelcomeView(
                permissions: permissionCenter,
                onGrant: { [weak self] permission in
                    self?.grant(permission)
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
        permissionCenter.startMonitoring()
    }

    private func grant(_ permission: PrivacyPermission) {
        guard permissionCenter.state(of: permission) != .needsRelaunch else {
            relaunchFromMenu()
            return
        }
        Task { @MainActor in
            do {
                try await permissionCenter.grant(permission, beside: welcomeWindow)
            } catch {
                showErrorAlert(title: PermissionText.openSettingsFailedTitle, message: error.localizedDescription)
            }
        }
    }

    /// The menu and the picker send a missing screen recording permission
    /// here, where the welcome window guides the user through System
    /// Settings.
    @objc private func grantScreenRecordingAccess() {
        showWelcome()
        grant(.screenRecording)
    }

    private func setupHotkey() {
        HotkeyManager.shared.onTrigger = { [weak self] action in
            switch action {
            case .toggleRecording:
                self?.handleToggleRecording()
            case .pauseRecording:
                self?.screenRecorder.togglePause()
            case .discardRecording:
                // No confirmation on the shortcut: it is a deliberate chord,
                // and a modal here would land in the middle of a demo. The
                // menu item, which sits next to Stop Recording and is easy to
                // mis-click, does confirm.
                self?.discardRecording(confirmed: true)
            }
        }

        HotkeyManager.shared.onHotkeyDisabled = { [weak self] message in
            self?.showHotkeyDisabledAlert(message: message)
        }

        HotkeyManager.shared.start()
    }

    private func handleToggleRecording() {
        switch RecordingToggleLogic.action(
            isRecording: screenRecorder.isRecording,
            hasPendingStart: recordingStartTask != nil
        ) {
        case .stop:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.stopRecordingFlow()
            }
        case .cancelPendingStart:
            cancelPendingRecordingStart()
        case .start:
            recordingStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.recordingStartTask = nil }

                // Check permission and available displays before starting.
                guard self.screenRecorder.hasPermission,
                    !self.screenRecorder.availableDisplays.isEmpty
                else {
                    self.showRecordingDialog()
                    return
                }
                // Fall back to the picker when the remembered selection no
                // longer exists (window closed, display unplugged).
                guard await self.screenRecorder.validateSelectionForQuickStart(),
                    !Task.isCancelled
                else {
                    if !Task.isCancelled {
                        self.showRecordingDialog()
                    }
                    return
                }

                await self.startCurrentTarget(overrides: .none)
            }
        }
    }

    private func cancelPendingRecordingStart() {
        recordingStartTask?.cancel()
        activeCountdown?.cancel()
        hideCameraOverlay()
        screenRecorder.discardCameraPreview()
    }

    /// Surfaces start failures (and degraded starts, e.g. mic didn't come up)
    /// as alerts instead of leaving them buried in the status item menu.
    private func reportStartOutcome() {
        guard let message = screenRecorder.errorMessage else { return }
        let title =
            screenRecorder.isRecording
            ? AppMenuText.recordingWarning
            : AppMenuText.recordingFailed
        showErrorAlert(title: title, message: message)
    }

    private func handleUnexpectedStop() {
        RecordingCue.stop.play()
        rebuildMenu()
        if let message = screenRecorder.errorMessage {
            showErrorAlert(title: AppMenuText.recordingStopped, message: message)
        }
        if AppSettings.shared.showPreviewAfterRecording,
            let url = screenRecorder.lastRecordedURL
        {
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
        let isRightClick =
            event?.type == .rightMouseUp
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
        let header = NSMenuItem(title: PermissionText.required, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(
            NSMenuItem(
                title: PermissionText.grantAccess,
                action: #selector(grantScreenRecordingAccess),
                keyEquivalent: ""
            ))
        if AppRelauncher.isAvailable {
            menu.addItem(
                NSMenuItem(title: PermissionText.relaunch, action: #selector(relaunchFromMenu), keyEquivalent: ""))
        }
    }

    private func addRecordingItems(to menu: NSMenu) {
        guard screenRecorder.isRecording else {
            let startItem = NSMenuItem(
                title: AppMenuText.startRecording, action: #selector(showRecordingDialog), keyEquivalent: "")
            menu.addItem(startItem)
            // The toggle shortcut records the remembered target without the
            // picker, so it labels that item. With nothing remembered, the
            // shortcut opens the picker, and labels Start Recording instead.
            guard let quickTitle = quickRecordTitle else {
                showShortcut(of: .toggleRecording, on: startItem)
                return
            }
            let quickItem = NSMenuItem(title: quickTitle, action: #selector(recordRememberedTarget), keyEquivalent: "")
            showShortcut(of: .toggleRecording, on: quickItem)
            menu.addItem(quickItem)
            return
        }
        let recordingItem = NSMenuItem(
            title: screenRecorder.isPaused ? AppMenuText.recordingPaused : AppMenuText.recordingInProgress,
            action: nil,
            keyEquivalent: ""
        )
        recordingItem.isEnabled = false
        menu.addItem(recordingItem)
        let pauseItem = NSMenuItem(
            title: screenRecorder.isPaused ? AppMenuText.resumeRecording : AppMenuText.pauseRecording,
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        showShortcut(of: .pauseRecording, on: pauseItem)
        menu.addItem(pauseItem)
        let stopItem = NSMenuItem(title: AppMenuText.stopRecording, action: #selector(stopRecording), keyEquivalent: "")
        showShortcut(of: .toggleRecording, on: stopItem)
        menu.addItem(stopItem)
        let discardItem = NSMenuItem(
            title: AppMenuText.discardRecording, action: #selector(discardRecordingFromMenu), keyEquivalent: "")
        showShortcut(of: .discardRecording, on: discardItem)
        menu.addItem(discardItem)
    }

    private func showShortcut(of action: HotkeyAction, on item: NSMenuItem) {
        guard let combo = AppSettings.shared.hotkey(for: action), let shortcut = MenuShortcut(combo) else { return }
        item.keyEquivalent = shortcut.key
        item.keyEquivalentModifierMask = shortcut.modifiers
    }

    @objc private func recordRememberedTarget() {
        handleToggleRecording()
    }

    private func addRecordingsAccessItems(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: AppMenuText.openRecordingsFolder, action: #selector(openRecordingsFolder), keyEquivalent: ""))

        let recents = AppSettings.shared.existingRecentRecordings
        guard !recents.isEmpty else { return }

        let submenu = NSMenu()
        for url in recents {
            let item = NSMenuItem(
                title: url.lastPathComponent, action: #selector(openRecentRecording(_:)), keyEquivalent: "")
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
        // The default folder only exists once something has been recorded.
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            showErrorAlert(
                title: AppMenuText.couldNotOpenRecordingsFolder,
                message: "Reel could not create \(url.path(percentEncoded: false)): \(error.localizedDescription)"
            )
            return
        }
        if !NSWorkspace.shared.open(url) {
            showErrorAlert(
                title: AppMenuText.couldNotOpenRecordingsFolder,
                message: "Finder could not open \(url.path(percentEncoded: false))."
            )
        }
    }

    @objc private func openRecentRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if !NSWorkspace.shared.open(url) {
            showErrorAlert(
                title: AppMenuText.couldNotOpenRecording,
                message: "Could not open \(url.path(percentEncoded: false)). The file may have been moved or deleted."
            )
        }
    }

    private func addErrorItems(to menu: NSMenu) {
        // Without permission the header already says what is wrong; the raw
        // ScreenCaptureKit error beneath it would add nothing.
        if screenRecorder.hasPermission, let error = screenRecorder.errorMessage {
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
            menu.addItem(
                NSMenuItem(title: AppMenuText.checkForUpdates, action: #selector(checkForUpdates), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: AppMenuText.settings, action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: AppMenuText.quitReel, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeWindow<Content: View>(
        title: String,
        styleMask: NSWindow.StyleMask,
        rootView: Content
    ) -> NSWindow {
        makeWindow(title: title, styleMask: styleMask, contentViewController: NSHostingController(rootView: rootView))
    }

    private func makeWindow(
        title: String,
        styleMask: NSWindow.StyleMask,
        contentViewController: NSViewController
    ) -> NSWindow {
        configure(NSWindow(contentViewController: contentViewController), title: title, styleMask: styleMask)
    }

    private func configure<Window: NSWindow>(_ window: Window, title: String, styleMask: NSWindow.StyleMask) -> Window {
        window.title = title
        window.styleMask = styleMask
        // A SwiftUI window has no size until it is shown, so centering it
        // first would put its top-left corner at the middle of the screen.
        if let content = window.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    /// Reel's own windows. While any is open, Reel shows in the Dock and
    /// Command-Tab like any app, so a window behind others can be found.
    private var openWindows: [NSWindow] {
        [settingsWindow, recordingDialogWindow, aboutWindow, welcomeWindow].compactMap { $0 } + previewWindows
    }

    /// Dragging a preview's title bar icon hands out what Copy and Share do:
    /// the recording until it is edited, then the rendered edits.
    func window(
        _ window: NSWindow,
        shouldDragDocumentWith event: NSEvent,
        from dragImageLocation: NSPoint,
        with pasteboard: NSPasteboard
    ) -> Bool {
        guard let preview = window as? PreviewWindow else { return true }
        if let file = preview.shareSource.readyFile() {
            pasteboard.clearContents()
            pasteboard.writeObjects([file as NSURL])
            return true
        }
        preview.beginPromisedFileDrag(with: event)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window === settingsWindow {
            settingsWindow = nil
        } else if window === recordingDialogWindow {
            recordingDialogWindow = nil
        } else if previewWindows.contains(where: { $0 === window }) {
            previewWindows.removeAll { $0 === window }
        } else if window === aboutWindow {
            aboutWindow = nil
        } else if window === welcomeWindow {
            welcomeWindow = nil
            permissionCenter.stopMonitoring()
            AppSettings.shared.hasShownWelcome = true
        }

        if openWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func presentWindow(_ window: NSWindow?) {
        guard let window else { return }

        NSApp.setActivationPolicy(.regular)
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

    @objc private func relaunchFromMenu() {
        Task { @MainActor in
            do {
                try await AppRelauncher.relaunch()
            } catch {
                showErrorAlert(title: PermissionText.relaunchFailedTitle, message: error.localizedDescription)
            }
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

    @objc private func stopRecording() {
        Task { @MainActor in
            await stopRecordingFlow()
        }
    }

    @objc private func togglePause() {
        screenRecorder.togglePause()
    }

    /// Freezes the elapsed readout while paused, so it reflects what is in
    /// the file.
    private func updatePauseState(_ isPaused: Bool) {
        if isPaused {
            pausedAt = Date()
        } else if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }

        applyStatusItemAppearance()
        updateElapsedTitle()
        rebuildMenu()
    }

    @objc private func discardRecordingFromMenu() {
        discardRecording(confirmed: false)
    }

    /// Ends the take and deletes it. Callers that already represent an
    /// unambiguous request — the global shortcut — pass confirmed.
    private func discardRecording(confirmed: Bool) {
        guard screenRecorder.isRecording else { return }
        guard confirmed || confirmDiscard() else { return }

        Task { @MainActor in
            hideCameraOverlay()
            guard await screenRecorder.discardRecording() else { return }
            RecordingCue.stop.play()
            rebuildMenu()
            if let message = screenRecorder.errorMessage {
                showErrorAlert(title: AppMenuText.recordingWarning, message: message)
            }
        }
    }

    private func confirmDiscard() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = AppMenuText.discardConfirmationTitle
        alert.informativeText = AppMenuText.discardConfirmationMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppMenuText.discard)
        alert.addButton(withTitle: AppMenuText.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func stopRecordingFlow() async {
        hideCameraOverlay()
        guard await screenRecorder.stopRecording() else { return }
        RecordingCue.stop.play()
        rebuildMenu()
        if AppSettings.shared.showPreviewAfterRecording,
            let url = screenRecorder.lastRecordedURL
        {
            showPreview(for: url)
        }
        if let message = screenRecorder.errorMessage {
            showErrorAlert(title: AppMenuText.recordingWarning, message: message)
        }
    }

    /// Runs the "Ask each time" save panel on the recorder's behalf.
    private func promptForSaveDestination(_ request: SaveDestinationRequest) async -> URL? {
        // As a menu bar (accessory) app there is usually no key window when a
        // recording stops; without activation the save panel can open behind
        // the frontmost app.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = request.suggestedName
        panel.directoryURL = request.directory

        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: keyWindow)
        } else {
            response = panel.runModal()
        }

        guard response == .OK else { return nil }
        return panel.url
    }

    private func showPreview(for url: URL) {
        // Each preview's buttons act on their own window, never on whichever
        // preview opened last.
        weak var window: NSWindow?
        let undoCommands = PreviewUndoCommands()
        let shareSource = PreviewShareSource()
        let previewView = PostRecordingView(
            videoURL: url,
            undoCommands: undoCommands,
            shareSource: shareSource,
            onDismiss: { [weak self] in
                self?.closePreview(window)
            },
            onRevealInFinder: {
                let revealed = NSWorkspace.shared.selectFile(url.path(percentEncoded: false), inFileViewerRootedAtPath: "")
                if !revealed {
                    let alert = NSAlert()
                    alert.messageText = AppMenuText.couldNotRevealRecording
                    alert.informativeText = "Finder could not reveal the recording at \(url.path(percentEncoded: false))."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            },
            onRecordAgain: { [weak self] in
                self?.closePreview(window) {
                    self?.handleToggleRecording()
                }
            },
            onChangeTarget: { [weak self] in
                self?.closePreview(window) {
                    self?.showRecordingDialog()
                }
            },
            onDelete: { [weak self] in
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = AppMenuText.couldNotDeleteRecording
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
                AppSettings.shared.forgetRecentRecording(url)
                if self?.screenRecorder.lastRecordedURL == url {
                    self?.screenRecorder.lastRecordedURL = nil
                }
                self?.rebuildMenu()
                window?.close()
            }
        )

        let hostingController = NSHostingController(rootView: previewView)
        // Lets the preview's SwiftUI toolbar become the window's toolbar.
        hostingController.sceneBridgingOptions = [.toolbars]
        // Named after the recording, with its file icon in the title bar to
        // drag, or Command-click for its folder, as in any document window.
        let previewWindow = configure(
            PreviewWindow(contentViewController: hostingController),
            title: FileManager.default.displayName(atPath: url.path(percentEncoded: false)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable]
        )
        previewWindow.representedURL = url
        previewWindow.toolbarStyle = .unified
        previewWindow.undoCommands = undoCommands
        previewWindow.shareSource = shareSource
        if let previous = previewWindows.last, let visibleFrame = previous.screen?.visibleFrame {
            previewWindow.setFrame(
                PreviewPlacement.cascadedFrame(previewWindow.frame, after: previous.frame, within: visibleFrame),
                display: false
            )
        }
        window = previewWindow
        previewWindows.append(previewWindow)
        presentWindow(previewWindow)
    }

    /// Closes a preview, then runs `then`. Edits are already saved with the
    /// recording.
    private func closePreview(_ window: NSWindow?, then: @escaping @MainActor () -> Void = {}) {
        guard let window else { return }
        window.close()
        then()
    }

    @objc private func showRecordingDialog() {
        if let recordingDialogWindow {
            presentWindow(recordingDialogWindow)
            return
        }
        guard !isPresentingRecordingDialog else { return }
        isPresentingRecordingDialog = true

        Task { @MainActor in
            defer { isPresentingRecordingDialog = false }
            await screenRecorder.refreshWindows()

            let dialogView = RecordingDialog(
                availableDisplays: screenRecorder.availableDisplays,
                availableWindows: screenRecorder.availableWindows,
                excludedApplications: screenRecorder.captureExcludedApplications,
                initialSelection: currentRecordingSelection,
                lastRegionOutputSize: screenRecorder.selectedRegionOutputSize,
                initialOverrides: RecordingOverrides(
                    recordAudio: AppSettings.shared.recordAudio,
                    recordCamera: AppSettings.shared.recordCamera
                ),
                onStart: { [weak self] selection, overrides in
                    guard let self else { return }
                    self.recordingDialogWindow?.close()
                    self.recordingDialogWindow = nil
                    self.startRecording(selection: selection, overrides: overrides)
                },
                onCancel: { [weak self] in
                    self?.recordingDialogWindow?.close()
                    self?.recordingDialogWindow = nil
                },
                onGrantAccess: { [weak self] in
                    self?.recordingDialogWindow?.close()
                    self?.recordingDialogWindow = nil
                    self?.grantScreenRecordingAccess()
                },
                onRefresh: { [weak self] in
                    guard let self else { return ([], [], []) }
                    await self.screenRecorder.refreshWindows()
                    return (
                        self.screenRecorder.availableDisplays,
                        self.screenRecorder.availableWindows,
                        self.screenRecorder.captureExcludedApplications
                    )
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

    private var quickRecordTitle: String? {
        QuickRecordTitle.text(
            mode: screenRecorder.recordingMode,
            displayLabel: selectedDisplayLabel,
            windowLabel: screenRecorder.selectedWindow.map { window in
                RecordingDialogLogic.windowTitle(
                    appName: window.owningApplication?.applicationName,
                    windowTitle: window.title
                )
            },
            regionOutputSize: screenRecorder.selectedRegionOutputSize
        )
    }

    private var selectedDisplayLabel: String? {
        let displayIDs = screenRecorder.availableDisplays.map(\.displayID)
        guard let displayID = screenRecorder.selectedDisplayID,
            let index = displayIDs.firstIndex(of: displayID)
        else {
            return nil
        }
        return RecordingDialogLogic.quickRecordDisplayLabel(
            titles: RecordingDialogLogic.displayTitles(names: RecordingDialogLogic.screenNames(for: displayIDs)),
            index: index
        )
    }

    /// The recorder's current target expressed as a picker selection, so
    /// reopening the picker starts on whatever was recorded last instead of
    /// forcing a fresh choice every time.
    private var currentRecordingSelection: RecordingSelection? {
        switch screenRecorder.recordingMode {
        case .display:
            return screenRecorder.selectedDisplayID.map { .display($0) }
        case .window:
            return screenRecorder.selectedWindow.map { .window($0) }
        case .region:
            return screenRecorder.selectedRegionOutputSize == nil ? .region : .lastRegion
        }
    }

    private func startRecording(
        selection: RecordingSelection,
        overrides: RecordingOverrides
    ) {
        guard recordingStartTask == nil else { return }
        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recordingStartTask = nil }

            switch selection {
            case .display(let displayID):
                self.screenRecorder.selectedDisplayID = displayID
                self.screenRecorder.recordingMode = .display
            case .window(let window):
                self.screenRecorder.selectedWindow = window
                self.screenRecorder.recordingMode = .window
            case .region:
                guard let region = await RegionSelector().select(),
                    !Task.isCancelled
                else { return }
                self.screenRecorder.selectedRegion = region
                self.screenRecorder.recordingMode = .region
            case .lastRegion:
                guard self.screenRecorder.selectedRegion != nil else { return }
                self.screenRecorder.recordingMode = .region
            }

            await self.startCurrentTarget(overrides: overrides)
        }
    }

    private func startCurrentTarget(overrides: RecordingOverrides) async {
        guard !Task.isCancelled,
            !screenRecorder.isRecording,
            !screenRecorder.isStarting,
            await runCountdown(overrides: overrides),
            !Task.isCancelled
        else {
            return
        }

        guard await screenRecorder.startRecording(overrides: overrides) else {
            hideCameraOverlay()
            if !Task.isCancelled {
                reportStartOutcome()
            }
            rebuildMenu()
            return
        }

        guard !Task.isCancelled else {
            hideCameraOverlay()
            await screenRecorder.discardRecording()
            rebuildMenu()
            return
        }

        RecordingCue.start.play()
        recordingDidStart()
    }

    /// Runs the pre-recording countdown (if enabled) and returns true when
    /// recording should start.
    private func runCountdown(overrides: RecordingOverrides) async -> Bool {
        guard !isCountdownActive, !Task.isCancelled else { return false }
        isCountdownActive = true
        defer {
            activeCountdown = nil
            isCountdownActive = false
        }

        if await screenRecorder.prepareCameraPreview(overrides: overrides) {
            showCameraOverlayForCountdown()
        }
        guard !Task.isCancelled else {
            hideCameraOverlay()
            screenRecorder.discardCameraPreview()
            return false
        }

        let countdown = CountdownOverlay()
        activeCountdown = countdown
        let shouldStart = await countdown.show(
            targetFrame: screenRecorder.countdownTargetFrame,
            duration: AppSettings.shared.countdownDuration
        )

        guard shouldStart, !Task.isCancelled else {
            hideCameraOverlay()
            screenRecorder.discardCameraPreview()
            return false
        }

        return true
    }

    /// Brings up everything that accompanies a running recording.
    private func recordingDidStart() {
        guard screenRecorder.isRecording else { return }
        showCameraOverlayIfNeeded()
        showCaptureBoundsIfNeeded()
        startWindowTrackingIfNeeded()
        rebuildMenu()
        reportStartOutcome()
    }

    /// Shows the draggable camera overlay if camera recording is enabled.
    private func showCameraOverlayIfNeeded() {
        guard let options = screenRecorder.activeRecordingOptions, options.recordCamera else { return }
        presentCameraOverlay(
            position: options.cameraPosition,
            sizeFraction: options.cameraSizeFraction,
            shape: options.cameraShape
        )
    }

    /// Brings the camera bubble up during the countdown so the user frames
    /// themselves before the take rather than on camera. The overlay carries
    /// straight over into the recording.
    private func showCameraOverlayForCountdown() {
        let settings = AppSettings.shared
        presentCameraOverlay(
            position: settings.cameraPosition,
            sizeFraction: settings.cameraSizeFraction,
            shape: settings.cameraShape
        )
    }

    private func presentCameraOverlay(
        position: AppSettings.CameraOverlayPosition,
        sizeFraction: CGFloat,
        shape: AppSettings.CameraOverlayShape
    ) {
        // Already framed during the countdown: keep the overlay the user
        // positioned rather than replacing it.
        guard cameraOverlayController == nil,
            let session = screenRecorder.activeCameraCaptureSession,
            let bounds = screenRecorder.recordingBounds
        else {
            return
        }

        cameraOverlayController = CameraOverlayController()
        cameraOverlayController?.show(
            session: session,
            bounds: bounds,
            initialPosition: position,
            sizeFraction: sizeFraction,
            shape: shape,
            onPositionChanged: { [weak self] x, y in
                self?.screenRecorder.updateCameraOverlayPosition(x: x, y: y)
            },
            onSizeChanged: { [weak self] fraction in
                self?.screenRecorder.updateCameraOverlaySize(fraction: fraction)
            },
            onSizeChangeEnded: { fraction in
                AppSettings.shared.cameraSizeFraction = fraction
            }
        )
    }

    /// Hides the camera overlay window.
    private func hideCameraOverlay() {
        stopWindowTracking()
        cameraOverlayController?.hide()
        cameraOverlayController = nil
    }

    /// Window recordings follow the window wherever it goes, but the camera
    /// overlay's drag bounds and the capture bounds border were both placed at
    /// start. Poll the recorded window's frame and move them along with it.
    private func startWindowTrackingIfNeeded() {
        guard screenRecorder.isRecording,
            screenRecorder.recordingMode == .window,
            let windowID = screenRecorder.selectedWindow?.windowID
        else {
            return
        }

        let timer = Timer(timeInterval: WindowTracking.interval, repeats: true) { [weak self] _ in
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
        guard let quartzBounds = quartzWindowBounds(windowID: windowID) else { return }

        captureBoundsIndicator?.update(globalQuartzFrame: quartzBounds)

        if let controller = cameraOverlayController,
            let cocoaBounds = cocoaRect(fromQuartz: quartzBounds)
        {
            controller.updateBounds(cocoaBounds)
        }
    }

    /// Outlines what is being captured so the user can see exactly what lands
    /// in the file. Full-display recordings are left alone: a border around
    /// the whole screen is noise rather than information.
    private func showCaptureBoundsIfNeeded() {
        guard screenRecorder.isRecording,
            screenRecorder.recordingMode != .display,
            let frame = screenRecorder.countdownTargetFrame
        else {
            return
        }

        captureBoundsIndicator = CaptureBoundsIndicator()
        captureBoundsIndicator?.show(globalQuartzFrame: frame)
    }

    private func hideCaptureBounds() {
        captureBoundsIndicator?.hide()
        captureBoundsIndicator = nil
    }

    @objc private func openPreferences() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: AppMenuText.settingsWindowTitle,
                styleMask: [.titled, .closable, .miniaturizable],
                contentViewController: SettingsPane.makeTabViewController()
            )
        }

        presentWindow(settingsWindow)
    }

    private func updateIcon(isRecording: Bool) {
        if !isRecording {
            hideCameraOverlay()
            hideCaptureBounds()
        }

        applyStatusItemAppearance()

        if isRecording {
            startRecordingTimer()
        } else {
            stopRecordingTimer()
        }
        rebuildMenu()
    }

    private func applyStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let state = StatusItemState(isRecording: screenRecorder.isRecording, isPaused: screenRecorder.isPaused)
        var image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: "Reel")
        // The menu bar draws template images in its own color and ignores
        // contentTintColor, so a colored state needs a non-template image.
        if let tint = state.tint, let colored = image?.withSymbolConfiguration(.init(paletteColors: [.white, tint])) {
            colored.isTemplate = false
            image = colored
        }
        button.image = image
        switch state {
        case .idle:
            button.toolTip =
                quickRecordTitle.map { title in
                    AppSettings.shared.recordingHotkey.map { "Reel — \(title) (\($0.displayString))" }
                        ?? "Reel — \(title)"
                } ?? "Reel"
        case .recording:
            button.toolTip = AppMenuText.recordingToolTip
        case .paused:
            button.toolTip = AppMenuText.pausedToolTip
        }
    }

    /// Shows elapsed time next to the status icon while recording, so the
    /// user can see at a glance that the recording is actually rolling.
    private func startRecordingTimer() {
        guard recordingTimer == nil else { return }
        recordingStartedAt = Date()
        pausedTotal = 0
        pausedAt = nil
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
        pausedTotal = 0
        pausedAt = nil
        statusItem.button?.title = ""
    }

    private func updateElapsedTitle() {
        guard let start = recordingStartedAt, let button = statusItem.button else { return }
        let pausedSoFar = pausedTotal + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0)
        let elapsed = Int(Date().timeIntervalSince(start) - pausedSoFar)
        button.attributedTitle = NSAttributedString(
            string: " " + RecordingElapsedFormat.string(seconds: elapsed),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
        )
    }
}
