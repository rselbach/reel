import Carbon
import XCTest
@testable import Reel

private final class RestoreFailingFileManager: FileManager, @unchecked Sendable {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        if moveCount == 3 {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class BackupCleanupFailingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class PartialDestinationFailingFileManager: FileManager, @unchecked Sendable {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        if moveCount == 2 {
            try Data("partial".utf8).write(to: dstURL)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testCameraOverlayPositionNormalizedCoordinates() {
        XCTAssertEqual(AppSettings.CameraOverlayPosition.bottomLeft.normalizedCoordinates.x, 0.0)
        XCTAssertEqual(AppSettings.CameraOverlayPosition.bottomLeft.normalizedCoordinates.y, 0.0)

        XCTAssertEqual(AppSettings.CameraOverlayPosition.topRight.normalizedCoordinates.x, 1.0)
        XCTAssertEqual(AppSettings.CameraOverlayPosition.topRight.normalizedCoordinates.y, 1.0)
    }

    @MainActor
    func testRecordingOptionsSnapshotMatchesSettingsAtStart() {
        let settings = AppSettings.shared
        let options = RecordingOptions(settings: settings)

        XCTAssertEqual(options.frameRate, settings.frameRate)
        XCTAssertEqual(options.showCursor, settings.showCursor)
        XCTAssertEqual(options.videoBitrate, settings.videoQuality.bitrate)
        XCTAssertEqual(options.outputDirectory, settings.outputDirectory)
        XCTAssertEqual(options.askWhereToSave, settings.askWhereToSave)
        XCTAssertEqual(options.recordAudio, settings.recordAudio)
        XCTAssertEqual(options.recordCamera, settings.recordCamera)
        XCTAssertEqual(options.cameraShape, settings.cameraShape)
        XCTAssertEqual(options.cameraSizeFraction, settings.cameraSizeFraction)
        XCTAssertEqual(options.textOverlay?.text, settings.activeTextOverlayText)
    }

    @MainActor
    func testRecordingOptionsDoNotFollowLaterSettingsEdits() {
        let settings = AppSettings.shared
        let originalQuality = settings.videoQuality
        let originalCursor = settings.showCursor
        defer {
            settings.videoQuality = originalQuality
            settings.showCursor = originalCursor
        }

        settings.videoQuality = .low
        settings.showCursor = true
        let options = RecordingOptions(settings: settings)

        settings.videoQuality = .maximum
        settings.showCursor = false

        XCTAssertEqual(options.videoBitrate, AppSettings.VideoQuality.low.bitrate)
        XCTAssertTrue(options.showCursor)
    }

    @MainActor
    func testRecordingOptionsOnlyMirrorFrontFacingCameras() {
        var options = RecordingOptions(settings: AppSettings.shared)
        options.recordCamera = false
        options.cameraDevice = nil
        XCTAssertFalse(options.mirrorCamera)

        // Without a device the position is unknown, which must not be treated
        // as front-facing: external and continuity cameras report
        // .unspecified and are never mirrored.
        options.recordCamera = true
        XCTAssertFalse(options.mirrorCamera)
    }

    @MainActor
    func testDiskSpaceRequirementScalesWithBitrate() {
        let medium = AppSettings.VideoQuality.medium.bitrate
        let maximum = AppSettings.VideoQuality.maximum.bitrate

        XCTAssertEqual(RecordingDiskSpace.bytesPerSecond(bitrate: medium), 1_375_000)
        XCTAssertGreaterThan(
            RecordingDiskSpace.requiredBytes(bitrate: maximum),
            RecordingDiskSpace.requiredBytes(bitrate: medium)
        )
        XCTAssertEqual(
            RecordingDiskSpace.requiredBytes(bitrate: medium),
            RecordingDiskSpace.bytesPerSecond(bitrate: medium) * 120
        )
    }

    @MainActor
    func testDiskSpaceShortfallOnlyReportedBelowTheFloor() {
        let bitrate = AppSettings.VideoQuality.medium.bitrate
        let required = RecordingDiskSpace.requiredBytes(bitrate: bitrate)
        let directory = URL(fileURLWithPath: "/Users/troy/Movies", isDirectory: true)

        XCTAssertNil(
            RecordingDiskSpace.shortfallMessage(
                availableBytes: required,
                bitrate: bitrate,
                directory: directory
            )
        )
        XCTAssertNil(
            RecordingDiskSpace.shortfallMessage(
                availableBytes: required * 10,
                bitrate: bitrate,
                directory: directory
            )
        )

        let message = RecordingDiskSpace.shortfallMessage(
            availableBytes: required - 1,
            bitrate: bitrate,
            directory: directory
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Movies") ?? false)
        XCTAssertTrue(message?.contains("video quality") ?? false)
    }

    @MainActor
    func testDiskSpaceRecordableSecondsHandlesEmptyVolume() {
        let bitrate = AppSettings.VideoQuality.high.bitrate
        XCTAssertEqual(
            RecordingDiskSpace.recordableSeconds(availableBytes: 0, bitrate: bitrate),
            0
        )
        XCTAssertEqual(
            RecordingDiskSpace.recordableSeconds(availableBytes: -100, bitrate: bitrate),
            0
        )
        XCTAssertEqual(
            RecordingDiskSpace.recordableSeconds(
                availableBytes: RecordingDiskSpace.bytesPerSecond(bitrate: bitrate) * 30,
                bitrate: bitrate
            ),
            30,
            accuracy: 0.001
        )
    }

    @MainActor
    func testLowSpaceStopTriggersBeforeTheWriterRunsOut() {
        let bitrate = AppSettings.VideoQuality.medium.bitrate
        let perSecond = RecordingDiskSpace.bytesPerSecond(bitrate: bitrate)

        XCTAssertFalse(
            RecordingDiskSpace.isCriticallyLow(availableBytes: perSecond * 60, bitrate: bitrate)
        )
        XCTAssertTrue(
            RecordingDiskSpace.isCriticallyLow(availableBytes: perSecond * 10, bitrate: bitrate)
        )
        XCTAssertTrue(
            RecordingDiskSpace.isCriticallyLow(availableBytes: 0, bitrate: bitrate)
        )

        // The stop floor has to sit below the start floor, otherwise every
        // recording that is allowed to start stops itself immediately.
        XCTAssertLessThan(
            RecordingDiskSpace.stopSeconds,
            RecordingDiskSpace.minimumMinutes * 60
        )
    }

    @MainActor
    func testLowSpaceReasonNamesRemainingSpace() {
        let reason = RecordingDiskSpace.lowSpaceReason(availableBytes: 5_000_000)
        XCTAssertTrue(reason.contains("disk is almost full"))
        XCTAssertTrue(reason.contains("MB"))
    }

    @MainActor
    func testVideoQualityBitrates() {
        XCTAssertEqual(AppSettings.VideoQuality.low.bitrate, 5_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.medium.bitrate, 10_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.high.bitrate, 20_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.maximum.bitrate, 50_000_000)
    }

    @MainActor
    func testStoredSettingRawValuesAreStableKeys() {
        XCTAssertEqual(AppSettings.VideoQuality.medium.rawValue, "medium")
        XCTAssertEqual(AppSettings.AudioSource.systemAudio.rawValue, "systemAudio")
        XCTAssertEqual(AppSettings.CameraOverlayPosition.bottomRight.rawValue, "bottomRight")
        XCTAssertEqual(AppSettings.CameraOverlaySize.large.rawValue, "large")
        XCTAssertEqual(AppSettings.CameraOverlayShape.circle.rawValue, "circle")
        XCTAssertEqual(AppSettings.TextOverlayPosition.center.rawValue, "center")
    }

    @MainActor
    func testStoredSettingDecodingAcceptsStableKeysAndLegacyLabels() {
        XCTAssertEqual(AppSettings.VideoQuality.fromStored("medium"), .medium)
        XCTAssertEqual(AppSettings.VideoQuality.fromStored("Medium (10 Mbps)"), .medium)
        XCTAssertNil(AppSettings.VideoQuality.fromStored("bogus"))
        XCTAssertNil(AppSettings.VideoQuality.fromStored(nil))

        XCTAssertEqual(AppSettings.CameraOverlayPosition.fromStored("Bottom Right"), .bottomRight)
        XCTAssertEqual(AppSettings.CameraOverlaySize.fromStored("Large"), .large)
        XCTAssertEqual(AppSettings.CameraOverlayShape.fromStored("Circle"), .circle)
        XCTAssertEqual(AppSettings.TextOverlayPosition.fromStored("Center"), .center)
        XCTAssertEqual(AppSettings.AudioSource.fromStored("System Audio"), .systemAudio)
        XCTAssertEqual(AppSettings.AudioSource.fromStored("microphone"), .microphone)
    }

    @MainActor
    func testHotkeyActionIdentifiersAreDistinctAndNonZero() {
        let ids = HotkeyAction.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "Carbon needs a distinct id per hot key")
        XCTAssertFalse(ids.contains(0), "0 is reserved as an unset EventHotKeyID")
        XCTAssertEqual(HotkeyAction.toggleRecording.rawValue, 1)
    }

    @MainActor
    func testHotkeyDisplayStringForDefaultShortcut() {
        XCTAssertEqual(AppSettings.HotkeyCombo.default.displayString, "⇧⌘R")
    }

    @MainActor
    func testHotkeyDisplayStringUsesFallbackForUnknownKeyCode() {
        let combo = AppSettings.HotkeyCombo(keyCode: 255, modifiers: 0x100000)
        XCTAssertEqual(combo.displayString, "⌘?")
    }

    @MainActor
    func testHotkeyRequiresCommandControlOrOptionModifier() {
        XCTAssertTrue(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x100000).isUsableGlobalShortcut)
        XCTAssertTrue(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x40000).isUsableGlobalShortcut)
        XCTAssertTrue(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x80000).isUsableGlobalShortcut)
        XCTAssertTrue(AppSettings.HotkeyCombo.default.isUsableGlobalShortcut)
    }

    @MainActor
    func testHotkeyRejectsShiftOnlyShortcut() {
        XCTAssertFalse(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x20000).isUsableGlobalShortcut)
        XCTAssertFalse(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0).isUsableGlobalShortcut)
    }

    @MainActor
    func testHotkeyRecorderDecisionCancelsOnEscape() {
        XCTAssertEqual(
            HotkeyRecorderLogic.decision(keyCode: KeyCode.escape, modifierFlags: []),
            .cancel
        )
    }

    @MainActor
    func testHotkeyRecorderDecisionPassesThroughPlainKeys() {
        XCTAssertEqual(
            HotkeyRecorderLogic.decision(keyCode: KeyCode.r, modifierFlags: []),
            .passThrough
        )
    }

    @MainActor
    func testHotkeyRecorderDecisionRejectsShiftOnlyShortcut() {
        XCTAssertEqual(
            HotkeyRecorderLogic.decision(keyCode: KeyCode.r, modifierFlags: [.shift]),
            .reject
        )
    }

    @MainActor
    func testHotkeyRecorderDecisionRecordsUsableShortcutWithMaskedModifiers() {
        XCTAssertEqual(
            HotkeyRecorderLogic.decision(keyCode: KeyCode.r, modifierFlags: [.command, .shift, .capsLock]),
            .record(keyCode: KeyCode.r, modifiers: 0x120000)
        )
    }

    @MainActor
    func testFrameRateSanitizationUsesSafeFallback() {
        XCTAssertEqual(AppSettings.sanitizedFrameRate(0), 30)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(30), 30)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(60), 60)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(45), 30)
        XCTAssertEqual(AppSettings.defaultFrameRate, 30)
    }

    func testGitInfoURLValidation() {
        XCTAssertNotNil(GitInfo.commitURL(for: "abc1234"))
        XCTAssertNil(GitInfo.commitURL(for: "dev"))
        XCTAssertNil(GitInfo.commitURL(for: ""))
        XCTAssertNil(GitInfo.commitURL(for: "zzzzzzzz"))
        XCTAssertNil(GitInfo.commitURL(for: "   dev   \n"))
    }

    func testGitInfoNormalizesWhitespaceBeforeValidation() {
        let url = GitInfo.commitURL(for: "   deadbeef   ")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://github.com/rselbach/reel/commit/deadbeef")
    }

    func testScreenCapturePrivacySettingsLinkTargetsExpectedPane() {
        let url = SystemSettingsLink.screenCapturePrivacy
        XCTAssertEqual(url?.scheme, "x-apple.systempreferences")
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testPermissionMenuTextMatchesExpectedActions() {
        XCTAssertEqual(AppMenuText.screenRecordingPermissionRequired, "Screen Recording Permission Required")
        XCTAssertEqual(AppMenuText.openSystemSettings, "Open System Settings...")
        XCTAssertEqual(AppMenuText.checkPermission, "Check Permission")
        XCTAssertEqual(AppMenuText.unableToOpenSettings, "Unable to open settings")
        XCTAssertEqual(AppMenuText.failedToOpenPrivacySettings, "Failed to open system privacy settings.")
        XCTAssertEqual(AppMenuText.couldNotOpenSystemPreferences, "Could not open System Preferences.")
    }

    func testAppMenuTextMatchesRecordingAndStandardMenuItems() {
        XCTAssertEqual(AppMenuText.startRecording, "Start Recording...")
        XCTAssertEqual(AppMenuText.recordingInProgress, "● Recording...")
        XCTAssertEqual(AppMenuText.stopRecording, "Stop Recording")
        XCTAssertEqual(AppMenuText.aboutReel, "About Reel")
        XCTAssertEqual(AppMenuText.settings, "Settings...")
        XCTAssertEqual(AppMenuText.quitReel, "Quit Reel")
        XCTAssertEqual(AppMenuText.hotkeyError, "Hotkey Error")
    }

    func testAppMenuTextMatchesWindowTitlesAndPreviewWarnings() {
        XCTAssertEqual(AppMenuText.recordingPreviewTitle, "Recording Preview")
        XCTAssertEqual(AppMenuText.newRecordingTitle, "New Recording")
        XCTAssertEqual(AppMenuText.settingsWindowTitle, "Reel Settings")
        XCTAssertEqual(AppMenuText.couldNotRevealRecording, "Could not reveal recording")
        XCTAssertEqual(AppMenuText.couldNotDeleteRecording, "Could not delete recording")
    }

    func testPostRecordingTextMatchesPreviewActions() {
        XCTAssertEqual(PostRecordingText.loading, "Loading...")
        XCTAssertEqual(PostRecordingText.revealInFinder, "Reveal in Finder")
        XCTAssertEqual(PostRecordingText.delete, "Delete")
        XCTAssertEqual(PostRecordingText.saveTrimmed, "Save Trimmed...")
        XCTAssertEqual(PostRecordingText.done, "Done")
        XCTAssertEqual(PostRecordingText.deleteConfirmationTitle, "Delete recording?")
        XCTAssertEqual(PostRecordingText.deleteConfirmationMessage, "This will permanently remove the file from disk.")
    }

    func testSettingsTextMatchesGeneralRecordingAndShortcutControls() {
        XCTAssertEqual(SettingsText.generalTab, "General")
        XCTAssertEqual(SettingsText.recordingTab, "Recording")
        XCTAssertEqual(SettingsText.shortcutsTab, "Shortcuts")
        XCTAssertEqual(SettingsText.launchAtLogin, "Launch at login")
        XCTAssertEqual(SettingsText.saveRecordingsTo, "Save recordings to:")
        XCTAssertEqual(SettingsText.askEachTime, "Ask each time")
        XCTAssertEqual(SettingsText.fixedFolder, "Fixed folder")
        XCTAssertEqual(SettingsText.outputDirectoryNotWritable, "Cannot write to selected folder. Pick another location.")
        XCTAssertEqual(SettingsText.recordAudio, "Record audio")
        XCTAssertEqual(SettingsText.recordCamera, "Record camera overlay")
        XCTAssertEqual(SettingsText.addTextOverlay, "Add text overlay")
        XCTAssertEqual(SettingsText.defaultDevice, "Default")
        XCTAssertEqual(SettingsText.unavailableDevice, "Unavailable device")
        XCTAssertEqual(SettingsText.pressShortcut, "Press shortcut...")
    }

    @MainActor
    func testWelcomeTextPairsTheRelaunchNoteWithAnAction() {
        XCTAssertTrue(WelcomeText.relaunchNote.contains("relaunching Reel"))
        XCTAssertEqual(WelcomeText.relaunchNow, "Relaunch Reel")
        XCTAssertEqual(WelcomeText.relaunchFailedTitle, "Could not relaunch Reel")
    }

    @MainActor
    func testSettingsWindowIsTallEnoughForTheRecordingTab() {
        // The Recording tab is the tallest: 6 always-visible controls, 3
        // dividers, and up to 9 more rows once camera and text overlay are on.
        // Scrolling covers the overflow, but the common case should still fit.
        XCTAssertGreaterThanOrEqual(SettingsLayout.height, 480)
        XCTAssertEqual(SettingsLayout.width, 460)
    }

    @MainActor
    func testSettingsErrorTextMatchesLaunchAtLoginFailure() {
        XCTAssertEqual(SettingsErrorText.launchAtLoginUpdateFailed, "Failed to update launch at login")
    }

    func testSparkleInfoPlistConfigurationIsPresent() throws {
        let plist = try loadSourceInfoPlist()
        XCTAssertEqual(plist["SUFeedURL"] as? String, "https://rselbach.github.io/reel/appcast.xml")
        let publicKey = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertFalse(publicKey.isEmpty)
        XCTAssertNotEqual(publicKey, "SPARKLE_PUBLIC_KEY_PLACEHOLDER")
        XCTAssertEqual(AppMenuText.checkForUpdates, "Check for Updates...")
    }

    func testInfoPlistDeclaresMenuBarAppAndPermissionUsageDescriptions() throws {
        let plist = try loadSourceInfoPlist()

        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.rselbach.reel")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Reel")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")

        let microphoneUsage = try XCTUnwrap(plist["NSMicrophoneUsageDescription"] as? String)
        let cameraUsage = try XCTUnwrap(plist["NSCameraUsageDescription"] as? String)
        let screenUsage = try XCTUnwrap(plist["NSScreenCaptureUsageDescription"] as? String)
        XCTAssertFalse(microphoneUsage.isEmpty)
        XCTAssertFalse(cameraUsage.isEmpty)
        XCTAssertFalse(screenUsage.isEmpty)
    }

    func testEntitlementsAllowConfiguredAudioCameraAndHardenedRuntime() throws {
        let entitlements = try loadPropertyList(at: repoRoot().appendingPathComponent("Reel.entitlements"))

        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.device.camera"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.hardened-runtime"] as? Bool, true)
    }

    func testPackageManifestPinsMacOSPlatformAndSparkleDependency() throws {
        let manifest = try String(
            contentsOf: repoRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains(".macOS(.v26)"))
        XCTAssertTrue(manifest.contains("https://github.com/sparkle-project/Sparkle"))
        XCTAssertTrue(manifest.contains(".product(name: \"Sparkle\", package: \"Sparkle\")"))
        XCTAssertTrue(manifest.contains("exclude: [\"Info.plist\", \"AppIcon.icns\"]"))
    }

    func testReleaseWorkflowFetchesHistoryForChangelog() throws {
        let workflow = try String(
            contentsOf: repoRoot().appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("fetch-depth: 0"))
    }

    func testReleaseTagValidatorRequiresNumericSemanticVersion() throws {
        let script = repoRoot().appendingPathComponent("scripts/release/validate-release-tag.sh")

        let valid = try runProcess("/bin/bash", [script.path(), "1.2.3"])
        XCTAssertEqual(valid.exitCode, 0)
        XCTAssertEqual(valid.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1.2.3")

        for version in ["not-a-version", "1..2", "1_2", "1.2.3.4", "1.2.3-beta_1", "1.2.3;false"] {
            let invalid = try runProcess("/bin/bash", [script.path(), version])
            XCTAssertNotEqual(invalid.exitCode, 0, version)
            XCTAssertTrue(invalid.stderr.contains("Expected X.Y.Z"), version)
        }
    }

    func testGenerateAppcastWritesSanitizedVersionAndSignedEnclosure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("appcast.xml")
        let script = repoRoot().appendingPathComponent("scripts/release/generate-appcast.sh")
        let signature = #"sparkle:edSignature="abc123" length="42""#

        let result = try runProcess("/bin/bash", [script.path(), "1.2.3", signature, outputURL.path()])
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)

        let appcast = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(appcast.contains("<title>Version 1.2.3</title>"))
        XCTAssertTrue(appcast.contains("<sparkle:version>1.2.3</sparkle:version>"))
        XCTAssertTrue(appcast.contains(#"url="https://github.com/rselbach/reel/releases/download/v1.2.3/Reel.dmg""#))
        XCTAssertTrue(appcast.contains(signature))
    }

    func testAboutGitHubRepositoryLinkTargetsProject() {
        XCTAssertEqual(AboutLinks.githubRepository?.absoluteString, "https://github.com/rselbach/reel")
    }

    func testRecordingDialogDisplayTitles() {
        XCTAssertEqual(RecordingDialogLogic.displayTitle(index: 0, displayCount: 1), "Display")
        XCTAssertEqual(RecordingDialogLogic.displayTitle(index: 0, displayCount: 2), "Display 1")
        XCTAssertEqual(RecordingDialogLogic.displayTitle(index: 1, displayCount: 2), "Display 2")
    }

    func testRecordingSelectionUsesStableDisplayID() {
        XCTAssertEqual(RecordingSelection.display(10), .display(10))
        XCTAssertNotEqual(RecordingSelection.display(10), .display(20))
    }

    func testRecordingDialogWindowTitleFallbacks() {
        XCTAssertEqual(
            RecordingDialogLogic.windowTitle(appName: "Safari", windowTitle: "Apple"),
            "Apple"
        )
        XCTAssertEqual(
            RecordingDialogLogic.windowTitle(appName: "Safari", windowTitle: "Safari"),
            "Safari"
        )
        XCTAssertEqual(
            RecordingDialogLogic.windowTitle(appName: nil, windowTitle: nil),
            "Unknown"
        )
    }

    @MainActor
    func testRecordingDialogTextDistinguishesEmptyStates() {
        XCTAssertEqual(RecordingDialogText.noWindows, "No open windows found.")
        XCTAssertEqual(
            RecordingDialogText.nothingRecordable,
            "No recordable displays or windows found"
        )
        XCTAssertNotEqual(
            RecordingDialogText.noWindows,
            RecordingDialogText.nothingRecordable
        )
        XCTAssertEqual(RecordingDialogText.openSystemSettings, AppMenuText.openSystemSettings)
    }

    @MainActor
    func testRecordingDialogWindowSearchMatchesAppOrTitleCaseInsensitively() {
        XCTAssertTrue(RecordingDialogLogic.windowMatchesSearch(
            appName: "Safari",
            windowTitle: "Apple Developer",
            query: "saf"
        ))
        XCTAssertTrue(RecordingDialogLogic.windowMatchesSearch(
            appName: "Safari",
            windowTitle: "Apple Developer",
            query: "developer"
        ))
        XCTAssertFalse(RecordingDialogLogic.windowMatchesSearch(
            appName: "Safari",
            windowTitle: "Apple Developer",
            query: "notes"
        ))
        XCTAssertTrue(RecordingDialogLogic.windowMatchesSearch(
            appName: nil,
            windowTitle: nil,
            query: ""
        ))
    }

    func testCountdownLayoutBuildsSequenceAndCentersHUD() {
        XCTAssertEqual(CountdownLayout.sequence(duration: 3), [3, 2, 1])
        XCTAssertEqual(CountdownLayout.sequence(duration: 5), [5, 4, 3, 2, 1])
        XCTAssertEqual(CountdownLayout.sequence(duration: 0), [])

        let frame = CountdownLayout.hudFrame(referenceFrame: CGRect(x: 50, y: 75, width: 1200, height: 800))
        XCTAssertEqual(frame.midX, 650)
        XCTAssertEqual(frame.midY, 475)
        XCTAssertEqual(frame.width, CountdownLayout.hudSize)
        XCTAssertEqual(frame.height, CountdownLayout.hudSize)
    }

    @MainActor
    func testCountdownCancelHintNamesTheRecordingShortcut() {
        XCTAssertEqual(
            CountdownLayout.cancelHint(shortcut: "⇧⌘R"),
            "Click or press ⇧⌘R to cancel"
        )
        XCTAssertFalse(CountdownLayout.cancelHint(shortcut: "⇧⌘R").contains("Esc"))
    }

    @MainActor
    func testCountdownDurationSanitizationAllowsOnlySupportedValues() {
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(0), 0)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(3), 3)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(5), 5)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(10), 10)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(7), 3)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(-1), 3)
    }

    @MainActor
    func testCameraSizeFractionSanitizationAndPresetMatching() {
        XCTAssertEqual(AppSettings.sanitizedCameraSizeFraction(0.01), CameraOverlayResizeLogic.minFraction)
        XCTAssertEqual(AppSettings.sanitizedCameraSizeFraction(0.9), CameraOverlayResizeLogic.maxFraction)
        XCTAssertEqual(AppSettings.sanitizedCameraSizeFraction(0.2), 0.2)

        let settings = AppSettings.shared
        let old = settings.cameraSizeFraction
        defer { settings.cameraSizeFraction = old }

        settings.cameraSizeFraction = 0.25
        XCTAssertEqual(settings.cameraSizePreset, .large)

        settings.cameraSizeFraction = 0.31
        XCTAssertNil(settings.cameraSizePreset)
    }

    func testCameraOverlayResizeCornerHitDetection() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertEqual(CameraOverlayResizeLogic.corner(at: CGPoint(x: 5, y: 5), in: bounds), .bottomLeft)
        XCTAssertEqual(CameraOverlayResizeLogic.corner(at: CGPoint(x: 195, y: 5), in: bounds), .bottomRight)
        XCTAssertEqual(CameraOverlayResizeLogic.corner(at: CGPoint(x: 5, y: 195), in: bounds), .topLeft)
        XCTAssertEqual(CameraOverlayResizeLogic.corner(at: CGPoint(x: 195, y: 195), in: bounds), .topRight)
        // Center and edge midpoints move rather than resize
        XCTAssertNil(CameraOverlayResizeLogic.corner(at: CGPoint(x: 100, y: 100), in: bounds))
        XCTAssertNil(CameraOverlayResizeLogic.corner(at: CGPoint(x: 100, y: 5), in: bounds))
        // Bounds smaller than two hit regions: everything is ambiguous, so move
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 20)
        XCTAssertNil(CameraOverlayResizeLogic.corner(at: CGPoint(x: 10, y: 10), in: tiny))
    }

    func testCameraOverlayResizeAnchorsOppositeCornerAndClamps() {
        let initial = CGRect(x: 100, y: 100, width: 100, height: 100)

        // Dragging the top-right corner outward grows the square while the
        // bottom-left corner stays fixed; the dominant axis (x) wins.
        let grown = CameraOverlayResizeLogic.resizedFrame(
            corner: .topRight, initialFrame: initial,
            deltaX: 40, deltaY: 10, minSide: 50, maxSide: 300
        )
        XCTAssertEqual(grown, CGRect(x: 100, y: 100, width: 140, height: 140))

        // Dragging the bottom-left corner keeps the top-right corner fixed.
        let fromBottomLeft = CameraOverlayResizeLogic.resizedFrame(
            corner: .bottomLeft, initialFrame: initial,
            deltaX: -40, deltaY: 10, minSide: 50, maxSide: 300
        )
        XCTAssertEqual(fromBottomLeft.maxX, 200)
        XCTAssertEqual(fromBottomLeft.maxY, 200)
        XCTAssertEqual(fromBottomLeft.width, 140)

        let clamped = CameraOverlayResizeLogic.resizedFrame(
            corner: .topRight, initialFrame: initial,
            deltaX: 500, deltaY: 0, minSide: 50, maxSide: 150
        )
        XCTAssertEqual(clamped.width, 150)

        let shrunk = CameraOverlayResizeLogic.resizedFrame(
            corner: .topRight, initialFrame: initial,
            deltaX: -90, deltaY: 0, minSide: 50, maxSide: 300
        )
        XCTAssertEqual(shrunk.width, 50)
    }

    @MainActor
    func testCameraOverlayLayoutConvertsNormalizedPositionToScreenOrigin() {
        let bounds = CGRect(x: 100, y: 200, width: 1000, height: 500)
        let origin = CameraOverlayLayout.originFromNormalized(
            x: 1,
            y: 0,
            overlaySize: 200,
            bounds: bounds
        )

        XCTAssertEqual(origin.x, 900)
        XCTAssertEqual(origin.y, 200)
    }

    @MainActor
    func testCameraOverlayLayoutCapsSizeToShortCaptureBounds() {
        XCTAssertEqual(
            CameraOverlayLayout.overlaySize(
                sizeFraction: 0.2,
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 500)
            ),
            200
        )
        XCTAssertEqual(
            CameraOverlayLayout.overlaySize(
                sizeFraction: 0.2,
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 100)
            ),
            100
        )
    }

    @MainActor
    func testCameraOverlayLayoutRoundTripsDraggedPosition() throws {
        let bounds = CGRect(x: 100, y: 200, width: 1000, height: 500)
        let origin = CGPoint(x: 500, y: 350)
        let position = try XCTUnwrap(CameraOverlayLayout.normalizedPosition(
            origin: origin,
            overlaySize: 200,
            bounds: bounds
        ))

        let roundTripOrigin = CameraOverlayLayout.originFromNormalized(
            x: position.x,
            y: position.y,
            overlaySize: 200,
            bounds: bounds
        )

        XCTAssertEqual(roundTripOrigin.x, origin.x, accuracy: 0.001)
        XCTAssertEqual(roundTripOrigin.y, origin.y, accuracy: 0.001)
    }

    @MainActor
    func testCameraOverlayLayoutRejectsOversizedOverlayForNormalization() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(CameraOverlayLayout.normalizedPosition(
            origin: .zero,
            overlaySize: 100,
            bounds: bounds
        ))
    }

    @MainActor
    func testActiveTextOverlayTrimsWhitespaceAndRequiresEnabledText() {
        let settings = AppSettings.shared
        let oldEnabled = settings.textOverlayEnabled
        let oldText = settings.textOverlayText
        defer {
            settings.textOverlayEnabled = oldEnabled
            settings.textOverlayText = oldText
        }

        settings.textOverlayEnabled = false
        settings.textOverlayText = " Hello "
        XCTAssertNil(settings.activeTextOverlayText)

        settings.textOverlayEnabled = true
        settings.textOverlayText = "   "
        XCTAssertNil(settings.activeTextOverlayText)

        settings.textOverlayText = " Hello "
        XCTAssertEqual(settings.activeTextOverlayText, "Hello")
    }

    @MainActor
    func testGitInfoNormalizesUppercaseCommits() {
        let uppercase = "ABCDEF1234567890"
        XCTAssertEqual(GitInfo.normalizedCommit(uppercase), uppercase.lowercased())
        XCTAssertEqual(GitInfo.commitURL(for: uppercase)?.absoluteString, "https://github.com/rselbach/reel/commit/abcdef1234567890")
    }

    @MainActor
    func testGitInfoAcceptsFullSHA() {
        // A git SHA is exactly 40 hex chars; the previous value was 42 and
        // was correctly rejected by isValidCommitSHA, failing the test.
        let fullSHA = "0123456789abcdefabcdef0123456789abcdef01"
        XCTAssertEqual(GitInfo.normalizedCommit(fullSHA), fullSHA.lowercased())
    }

    func testRecentRecordingsDeduplicateAndCapMostRecentFirst() {
        XCTAssertEqual(
            RecentRecordingsLogic.updatedPaths(current: [], adding: "/a.mp4", limit: 5),
            ["/a.mp4"]
        )
        XCTAssertEqual(
            RecentRecordingsLogic.updatedPaths(current: ["/a.mp4", "/b.mp4"], adding: "/b.mp4", limit: 5),
            ["/b.mp4", "/a.mp4"]
        )
        XCTAssertEqual(
            RecentRecordingsLogic.updatedPaths(
                current: ["/1.mp4", "/2.mp4", "/3.mp4", "/4.mp4", "/5.mp4"],
                adding: "/6.mp4",
                limit: 5
            ),
            ["/6.mp4", "/1.mp4", "/2.mp4", "/3.mp4", "/4.mp4"]
        )
    }

    func testRegionMathConvertsCocoaSelectionToQuartz() {
        let quartz = RegionMath.quartzRect(
            fromScreenLocalCocoa: CGRect(x: 100, y: 100, width: 400, height: 200),
            screenHeight: 900
        )
        XCTAssertEqual(quartz, CGRect(x: 100, y: 600, width: 400, height: 200))
    }

    func testRegionMathPlacesRegionInGlobalQuartzSpace() {
        let global = RegionMath.globalQuartzFrame(
            regionRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            displayFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        )
        XCTAssertEqual(global, CGRect(x: 1450, y: 20, width: 300, height: 200))
    }

    func testScreenCoordinateConversionHandlesDisplayAbovePrimary() {
        let primaryFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let upperDisplayQuartzFrame = CGRect(x: 0, y: -1080, width: 1920, height: 1080)

        XCTAssertEqual(
            ScreenCoordinateConversion.cocoaRect(
                fromQuartz: upperDisplayQuartzFrame,
                primaryScreenFrame: primaryFrame
            ),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        )
    }

    func testScreenCoordinateConversionHandlesDisplayBelowPrimary() {
        let primaryFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let lowerDisplayQuartzFrame = CGRect(x: 0, y: 1080, width: 1920, height: 1080)

        XCTAssertEqual(
            ScreenCoordinateConversion.cocoaRect(
                fromQuartz: lowerDisplayQuartzFrame,
                primaryScreenFrame: primaryFrame
            ),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        )
    }

    func testCameraCompositeSquareCropCentersOnLongAxis() {
        let landscape = CameraCompositeLayout.squareCropRect(width: 1920, height: 1080)
        XCTAssertEqual(landscape, CGRect(x: 420, y: 0, width: 1080, height: 1080))

        let portrait = CameraCompositeLayout.squareCropRect(width: 1080, height: 1920)
        XCTAssertEqual(portrait, CGRect(x: 0, y: 420, width: 1080, height: 1080))

        let square = CameraCompositeLayout.squareCropRect(width: 720, height: 720)
        XCTAssertEqual(square, CGRect(x: 0, y: 0, width: 720, height: 720))
    }

    @MainActor
    func testRecordingDimensionsStayUnchangedWhenInsideH264Limits() {
        let dimensions = ScreenRecorder.dimensionsFittingH264Limits(width: 1920, height: 1080)
        XCTAssertEqual(dimensions.width, 1920)
        XCTAssertEqual(dimensions.height, 1080)
    }

    @MainActor
    func testRecordingDimensionsDownscaleLargeLandscapeCaptureForH264() {
        let dimensions = ScreenRecorder.dimensionsFittingH264Limits(width: 5120, height: 2880)
        XCTAssertEqual(dimensions.width, 4096)
        XCTAssertEqual(dimensions.height, 2304)
    }

    @MainActor
    func testRecordingDimensionsDownscaleLargePortraitCaptureForH264() {
        let dimensions = ScreenRecorder.dimensionsFittingH264Limits(width: 2880, height: 5120)
        XCTAssertEqual(dimensions.width, 1296)
        XCTAssertEqual(dimensions.height, 2304)
    }

    @MainActor
    func testRecordingDimensionsLeaveInvalidValuesForExistingValidation() {
        let dimensions = ScreenRecorder.dimensionsFittingH264Limits(width: 0, height: 1080)
        XCTAssertEqual(dimensions.width, 0)
        XCTAssertEqual(dimensions.height, 1080)
    }

    func testRecordingFileNamingUsesReelPrefixTimestampRandomIDAndMP4Extension() {
        let date = Date(timeIntervalSince1970: 0)
        let filename = RecordingFileNaming.fileName(date: date, randomID: "ABC12345")

        XCTAssertEqual(filename, "Reel-1970-01-01T00-00-00Z-ABC12345.mp4")
        XCTAssertFalse(RecordingFileNaming.sanitizedTimestamp(from: date).contains(":"))
    }

    func testRecordingFinalizationRevealsFinderOnlyWhenPreviewIsDisabled() {
        XCTAssertTrue(RecordingFinalizationLogic.shouldRevealInFinder(
            openFinderAfterRecording: true,
            showPreviewAfterRecording: false
        ))
        XCTAssertFalse(RecordingFinalizationLogic.shouldRevealInFinder(
            openFinderAfterRecording: true,
            showPreviewAfterRecording: true
        ))
        XCTAssertFalse(RecordingFinalizationLogic.shouldRevealInFinder(
            openFinderAfterRecording: false,
            showPreviewAfterRecording: false
        ))
    }

    func testRecordingFinalizationFinderRevealFailureMessageIncludesPath() {
        let url = URL(fileURLWithPath: "/tmp/Reel-Test.mp4")
        XCTAssertEqual(
            RecordingFinalizationLogic.finderRevealFailureMessage(for: url),
            "Recording saved, but Finder could not reveal it: /tmp/Reel-Test.mp4"
        )
    }

    func testThumbnailSizingPreservesAspectRatioWithinMaximumSize() throws {
        let landscape = try XCTUnwrap(ThumbnailSizing.targetSize(
            sourceSize: CGSize(width: 1920, height: 1080),
            maxSize: CGSize(width: 320, height: 180)
        ))
        XCTAssertEqual(landscape.width, 320)
        XCTAssertEqual(landscape.height, 180)

        let portrait = try XCTUnwrap(ThumbnailSizing.targetSize(
            sourceSize: CGSize(width: 1080, height: 1920),
            maxSize: CGSize(width: 320, height: 180)
        ))
        XCTAssertEqual(portrait.width, 101)
        XCTAssertEqual(portrait.height, 180)

        XCTAssertNil(ThumbnailSizing.targetSize(
            sourceSize: CGSize(width: 0, height: 1080),
            maxSize: CGSize(width: 320, height: 180)
        ))
    }

    func testFileReplacementMovesNewFileIntoEmptyDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tempURL = directory.appendingPathComponent("trimmed.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("new".utf8).write(to: tempURL)

        try FileReplacement.commit(tempURL: tempURL, to: outputURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path()))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "new")
    }

    func testFileReplacementReplacesExistingDestinationAfterSuccessfulMove() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tempURL = directory.appendingPathComponent("trimmed.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("old".utf8).write(to: outputURL)
        try Data("new".utf8).write(to: tempURL)

        try FileReplacement.commit(tempURL: tempURL, to: outputURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path()))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "new")
    }

    func testFileReplacementRestoresExistingDestinationWhenCommitFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingTempURL = directory.appendingPathComponent("missing.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("old".utf8).write(to: outputURL)

        XCTAssertThrowsError(try FileReplacement.commit(tempURL: missingTempURL, to: outputURL))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "old")
    }

    func testFileReplacementRemovesPartialDestinationBeforeRollback() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove test directory: \(error)")
            }
        }

        let tempURL = directory.appendingPathComponent("recording.tmp.mp4")
        let outputURL = directory.appendingPathComponent("recording.mp4")
        try Data("new".utf8).write(to: tempURL)
        try Data("old".utf8).write(to: outputURL)

        XCTAssertThrowsError(try FileReplacement.commit(
            tempURL: tempURL,
            to: outputURL,
            fileManager: PartialDestinationFailingFileManager()
        ))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: tempURL, encoding: .utf8), "new")
    }

    func testFileReplacementReportsRollbackFailureAndPreservesBackup() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove test directory: \(error)")
            }
        }

        let missingTempURL = directory.appendingPathComponent("missing.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("old".utf8).write(to: outputURL)

        XCTAssertThrowsError(try FileReplacement.commit(
            tempURL: missingTempURL,
            to: outputURL,
            fileManager: RestoreFailingFileManager()
        )) { error in
            guard case FileReplacementError.rollbackFailed(_, _, let backupURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path()))
            let backupContents: String
            do {
                backupContents = try String(contentsOf: backupURL, encoding: .utf8)
            } catch {
                return XCTFail("Failed to read preserved backup: \(error)")
            }
            XCTAssertEqual(backupContents, "old")
        }
    }

    func testFileReplacementReportsBackupCleanupFailureAfterCommit() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove test directory: \(error)")
            }
        }

        let tempURL = directory.appendingPathComponent("trimmed.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("old".utf8).write(to: outputURL)
        try Data("new".utf8).write(to: tempURL)

        let warning = try FileReplacement.commit(
            tempURL: tempURL,
            to: outputURL,
            fileManager: BackupCleanupFailingFileManager()
        )

        XCTAssertNotNil(warning)
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: warning?.backupURL.path() ?? ""))
    }

    func testFileReplacementAllowsAlreadyFinalDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("recording.mp4")
        try Data("final".utf8).write(to: outputURL)

        try FileReplacement.commit(tempURL: outputURL, to: outputURL)

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "final")
    }

    func testStatusItemLeftClickStopsOnlyActiveRecordings() {
        XCTAssertTrue(StatusItemClickLogic.shouldStopRecording(isRecording: true, isRightClick: false))
        XCTAssertFalse(StatusItemClickLogic.shouldStopRecording(isRecording: true, isRightClick: true))
        XCTAssertFalse(StatusItemClickLogic.shouldStopRecording(isRecording: false, isRightClick: false))
        XCTAssertFalse(StatusItemClickLogic.shouldStopRecording(isRecording: false, isRightClick: true))
    }

    func testRecordingElapsedFormatCoversMinutesAndHours() {
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 0), "0:00")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 42), "0:42")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 65), "1:05")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 3600), "1:00:00")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 3725), "1:02:05")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: -5), "0:00")
    }

    func testAppTerminationReplyDefersForActiveOrStartingRecording() {
        XCTAssertEqual(
            AppTerminationLogic.reply(
                isRecorderInitialized: false,
                isRecording: false,
                isStarting: false
            ),
            .terminateNow
        )
        XCTAssertEqual(
            AppTerminationLogic.reply(
                isRecorderInitialized: true,
                isRecording: false,
                isStarting: false
            ),
            .terminateNow
        )
        XCTAssertEqual(
            AppTerminationLogic.reply(
                isRecorderInitialized: true,
                isRecording: true,
                isStarting: false
            ),
            .terminateLater
        )
        XCTAssertEqual(
            AppTerminationLogic.reply(
                isRecorderInitialized: true,
                isRecording: false,
                isStarting: true
            ),
            .terminateLater
        )
    }

    func testCarbonModifierTranslationMapsEventMasksToCarbonMasks() {
        // Default shortcut is Cmd+Shift (0x120000)
        XCTAssertEqual(
            CarbonModifierTranslation.carbonModifiers(fromEventModifiers: 0x120000),
            UInt32(cmdKey | shiftKey)
        )
        XCTAssertEqual(
            CarbonModifierTranslation.carbonModifiers(fromEventModifiers: 0x40000),
            UInt32(controlKey)
        )
        XCTAssertEqual(
            CarbonModifierTranslation.carbonModifiers(fromEventModifiers: 0x80000),
            UInt32(optionKey)
        )
        XCTAssertEqual(CarbonModifierTranslation.carbonModifiers(fromEventModifiers: 0), 0)
    }

    func testTrimSliderMathCalculatesPositionsAndFormattedTime() {
        XCTAssertEqual(
            TrimSliderMath.startPosition(trimStart: 2, duration: 10, width: 100),
            20
        )
        XCTAssertEqual(
            TrimSliderMath.endPosition(trimEnd: 8, duration: 10, width: 100),
            80
        )
        XCTAssertEqual(
            TrimSliderMath.playheadPosition(currentTime: 5, duration: 10, width: 100),
            50
        )
        XCTAssertEqual(TrimSliderMath.formattedTime(65.4), "1:05.4")
    }

    func testTrimSliderMathClampsSeekAndMaintainsMinimumRange() {
        XCTAssertEqual(
            TrimSliderMath.seekTime(locationX: -100, handleWidth: 12, usableWidth: 100, duration: 10),
            0
        )
        XCTAssertEqual(
            TrimSliderMath.seekTime(locationX: 500, handleWidth: 12, usableWidth: 100, duration: 10),
            10
        )
        XCTAssertEqual(
            TrimSliderMath.clampedStart(
                origin: 4.8,
                translationWidth: 100,
                usableWidth: 100,
                duration: 10,
                trimEnd: 5
            ),
            4.5
        )
        XCTAssertEqual(
            TrimSliderMath.clampedEnd(
                origin: 5.2,
                translationWidth: -100,
                usableWidth: 100,
                duration: 10,
                trimStart: 5
            ),
            5.5
        )
    }

    func testTrimSliderMathKeepsShortRecordingRangeValid() {
        XCTAssertEqual(
            TrimSliderMath.clampedStart(
                origin: 0,
                translationWidth: 100,
                usableWidth: 100,
                duration: 0.2,
                trimEnd: 0.2
            ),
            0
        )
        XCTAssertEqual(
            TrimSliderMath.clampedEnd(
                origin: 0.2,
                translationWidth: -100,
                usableWidth: 100,
                duration: 0.2,
                trimStart: 0
            ),
            0.2
        )
    }

    func testPostRecordingLogicShowsSaveTrimmedOnlyForMeaningfulTrimChanges() {
        XCTAssertFalse(PostRecordingLogic.hasTrimChanges(duration: 0, trimStart: 1, trimEnd: 5))
        XCTAssertFalse(PostRecordingLogic.hasTrimChanges(duration: 10, trimStart: 0.05, trimEnd: 9.95))
        XCTAssertTrue(PostRecordingLogic.hasTrimChanges(duration: 10, trimStart: 0.2, trimEnd: 10))
        XCTAssertTrue(PostRecordingLogic.hasTrimChanges(duration: 10, trimStart: 0, trimEnd: 9.8))
    }

    @MainActor
    func testTextOverlayLayoutCapsImageHeightForLongText() {
        let layout = TextOverlayLayout.imageSize(
            suggestedTextSize: CGSize(width: 1000, height: 5000),
            fontSize: 48,
            maxWidth: 1600,
            maxImageHeight: 360
        )

        XCTAssertLessThanOrEqual(layout.imageSize.height, 360)
        XCTAssertGreaterThan(layout.textRect.height, 0)
        XCTAssertLessThanOrEqual(layout.textRect.maxY, layout.imageSize.height)
    }

    @MainActor
    func testTextOverlayLayoutKeepsTopPositionVisible() {
        let yOffset = TextOverlayLayout.yOffset(
            screenHeight: 1080,
            overlayHeight: 360,
            margin: 43.2,
            position: .top
        )

        XCTAssertGreaterThanOrEqual(yOffset, 43.2)
        XCTAssertLessThanOrEqual(yOffset + 360, 1080 - 43.2)
    }

    @MainActor
    func testTextOverlayLayoutKeepsOversizedOverlayVisibleAsMuchAsPossible() {
        let yOffset = TextOverlayLayout.yOffset(
            screenHeight: 200,
            overlayHeight: 180,
            margin: 24,
            position: .center
        )

        XCTAssertEqual(yOffset, 24)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func loadSourceInfoPlist() throws -> [String: Any] {
        try loadPropertyList(at: repoRoot().appendingPathComponent("Sources/Info.plist"))
    }

    private func loadPropertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws -> (
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return (
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
