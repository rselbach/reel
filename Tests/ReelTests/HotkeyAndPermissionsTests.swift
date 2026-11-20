import AppKit
import Carbon
import XCTest

@testable import Reel

final class HotkeyAndPermissionsTests: XCTestCase {
    private func makeIsolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "com.rselbach.reel.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @MainActor
    func testCameraSizeFractionSanitizationHandlesNonFiniteValues() {
        XCTAssertEqual(AppSettings.sanitizedCameraSizeFraction(.nan), AppSettings.CameraOverlaySize.medium.fraction)
        XCTAssertEqual(
            AppSettings.sanitizedCameraSizeFraction(.infinity), AppSettings.CameraOverlaySize.medium.fraction)
        XCTAssertEqual(
            AppSettings.sanitizedCameraSizeFraction(-.infinity), AppSettings.CameraOverlaySize.medium.fraction)
    }

    @MainActor
    func testAssigningAndLoadingNonFiniteCameraSizeFractionFallsBackWithoutRecursing() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: "cameraSizeFraction")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.cameraSizeFraction, AppSettings.CameraOverlaySize.medium.fraction)

        settings.cameraSizeFraction = .nan
        XCTAssertEqual(settings.cameraSizeFraction, AppSettings.CameraOverlaySize.medium.fraction)

        settings.cameraSizeFraction = .infinity
        XCTAssertEqual(settings.cameraSizeFraction, AppSettings.CameraOverlaySize.medium.fraction)

        settings.cameraSizeFraction = -.infinity
        XCTAssertEqual(settings.cameraSizeFraction, AppSettings.CameraOverlaySize.medium.fraction)
    }

    @MainActor
    func testUnwritableOutputDirectoryFallsBackInMemoryWithoutOverwritingDefaults() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unpluggedDrivePath = "/Volumes/GreendaleExternal-\(UUID().uuidString)/Recordings"
        defaults.set(unpluggedDrivePath, forKey: "outputDirectory")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.outputDirectory, AppSettings.defaultOutputDirectory())
        XCTAssertEqual(defaults.string(forKey: "outputDirectory"), unpluggedDrivePath)
    }

    @MainActor
    func testDuplicateHotkeysAreDeduplicatedOnLoad() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let encoder = JSONEncoder()
        defaults.set(try encoder.encode(AppSettings.HotkeyCombo.default), forKey: "recordingHotkey")
        defaults.set(try encoder.encode(AppSettings.HotkeyCombo.default), forKey: "discardHotkey")
        defaults.set(try encoder.encode(AppSettings.HotkeyCombo.pauseDefault), forKey: "pauseHotkey")

        let fallbackSettings = AppSettings(defaults: defaults)
        XCTAssertEqual(fallbackSettings.recordingHotkey, .default)
        XCTAssertEqual(fallbackSettings.discardHotkey, .discardDefault)
        XCTAssertEqual(fallbackSettings.pauseHotkey, .pauseDefault)

        // When both the stored combo and the colliding action's default are
        // already claimed, the later action is turned off instead of colliding.
        defaults.set(try encoder.encode(AppSettings.HotkeyCombo.discardDefault), forKey: "recordingHotkey")
        defaults.set(try encoder.encode(AppSettings.HotkeyCombo.discardDefault), forKey: "discardHotkey")
        defaults.set(try encoder.encode(AppSettings.HotkeyCombo?.none), forKey: "pauseHotkey")

        let turnedOffSettings = AppSettings(defaults: defaults)
        XCTAssertEqual(turnedOffSettings.recordingHotkey, .discardDefault)
        XCTAssertNil(turnedOffSettings.discardHotkey)
        XCTAssertNil(turnedOffSettings.pauseHotkey)
    }

    @MainActor
    func testRecentRecordingPathsDeduplicateAfterLegacyDecodingAndCapOnLoad() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            [
                "/Users/troy/Movies/Reel/Reel 1.mp4",
                "/Users/troy/Movies/Reel/Reel%201.mp4",
                "/Users/troy/Movies/Reel/Reel 2.mp4",
                "/Users/troy/Movies/Reel/Reel 3.mp4",
                "/Users/troy/Movies/Reel/Reel 2.mp4",
                "/Users/troy/Movies/Reel/Reel 4.mp4",
                "/Users/troy/Movies/Reel/Reel 5.mp4",
                "/Users/troy/Movies/Reel/Reel 6.mp4",
            ],
            forKey: "recentRecordings"
        )

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(
            settings.recentRecordingPaths,
            [
                "/Users/troy/Movies/Reel/Reel 1.mp4",
                "/Users/troy/Movies/Reel/Reel 2.mp4",
                "/Users/troy/Movies/Reel/Reel 3.mp4",
                "/Users/troy/Movies/Reel/Reel 4.mp4",
                "/Users/troy/Movies/Reel/Reel 5.mp4",
            ]
        )
        XCTAssertEqual(settings.recentRecordingPaths.count, AppSettings.maxRecentRecordings)
    }

    @MainActor
    private func makeTestHotkeyManager(
        initialCombos: [HotkeyAction: AppSettings.HotkeyCombo?] = [
            .toggleRecording: .default,
            .discardRecording: .discardDefault,
            .pauseRecording: .pauseDefault,
        ],
        workspaceNotificationCenter: NotificationCenter = NotificationCenter(),
        shouldFailRegistration: @escaping (HotkeyAction, AppSettings.HotkeyCombo) -> Bool = { _, _ in false }
    ) -> (
        manager: HotkeyManager,
        activeRegistrations: () -> [HotkeyAction: AppSettings.HotkeyCombo],
        registerCallCount: () -> Int,
        unregisterCallCount: () -> Int
    ) {
        var active: [HotkeyAction: AppSettings.HotkeyCombo] = [:]
        var registerCalls = 0
        var unregisterCalls = 0

        let backend = HotkeyManager.RegistrationBackend(
            installEventHandler: { _ in (noErr, {}) },
            registerHotKey: { action, combo in
                registerCalls += 1
                if shouldFailRegistration(action, combo) {
                    return (OSStatus(eventHotKeyExistsErr), nil)
                }
                active[action] = combo
                return (
                    noErr,
                    {
                        unregisterCalls += 1
                        active.removeValue(forKey: action)
                    }
                )
            }
        )

        let manager = HotkeyManager(
            backend: backend,
            workspaceNotificationCenter: workspaceNotificationCenter,
            comboProvider: { initialCombos[$0] ?? nil }
        )
        return (
            manager,
            { active },
            { registerCalls },
            { unregisterCalls }
        )
    }

    @MainActor
    func testHotkeyManagerSuspendAndResumeNestAndSuppressFailureAlertsOnResume() {
        var failDiscard = false
        let harness = makeTestHotkeyManager(shouldFailRegistration: { action, _ in
            action == .discardRecording && failDiscard
        })
        let manager = harness.manager
        defer { manager.stop() }

        var disabledMessages: [String] = []
        manager.onHotkeyDisabled = { disabledMessages.append($0) }

        manager.start()
        XCTAssertEqual(harness.activeRegistrations().count, HotkeyAction.allCases.count)
        let registrationsAfterStart = harness.registerCallCount()

        manager.suspend()
        XCTAssertTrue(harness.activeRegistrations().isEmpty)
        let unregistrationsAfterFirstSuspend = harness.unregisterCallCount()

        manager.suspend()
        XCTAssertEqual(harness.unregisterCallCount(), unregistrationsAfterFirstSuspend)

        manager.resume()
        XCTAssertTrue(harness.activeRegistrations().isEmpty)
        XCTAssertEqual(harness.registerCallCount(), registrationsAfterStart)

        failDiscard = true
        manager.resume()
        XCTAssertEqual(harness.activeRegistrations()[.toggleRecording], .default)
        XCTAssertNil(harness.activeRegistrations()[.discardRecording])
        XCTAssertEqual(harness.activeRegistrations()[.pauseRecording], .pauseDefault)
        XCTAssertTrue(disabledMessages.isEmpty, "resume must not re-fire modal error alerts")

        // Extra unmatched resume is a safe no-op.
        let callsAfterResume = harness.registerCallCount()
        manager.resume()
        XCTAssertEqual(harness.registerCallCount(), callsAfterResume)
    }

    @MainActor
    func testHotkeyManagerDefersRegistrationWhenUpdatingHotkeysWhileSuspended() {
        let harness = makeTestHotkeyManager()
        let manager = harness.manager
        defer { manager.stop() }

        manager.start()
        manager.suspend()
        let callsWhileSuspended = harness.registerCallCount()

        let customToggle = AppSettings.HotkeyCombo(keyCode: KeyCode.f6, modifiers: 0x100000)
        let unusable = AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x20000)

        XCTAssertFalse(manager.updateHotkey(unusable, for: .toggleRecording))
        XCTAssertFalse(manager.updateHotkey(.discardDefault, for: .toggleRecording))
        XCTAssertTrue(manager.updateHotkey(customToggle, for: .toggleRecording))
        XCTAssertTrue(manager.updateHotkey(nil, for: .pauseRecording))
        XCTAssertEqual(harness.registerCallCount(), callsWhileSuspended)
        XCTAssertTrue(harness.activeRegistrations().isEmpty)

        manager.resume()
        XCTAssertEqual(harness.activeRegistrations()[.toggleRecording], customToggle)
        XCTAssertEqual(harness.activeRegistrations()[.discardRecording], .discardDefault)
        XCTAssertNil(harness.activeRegistrations()[.pauseRecording])

        // Bulk update while suspended also validates and defers until resume.
        manager.suspend()
        let callsBeforeBulk = harness.registerCallCount()

        let swapped: [HotkeyAction: AppSettings.HotkeyCombo] = [
            .toggleRecording: .pauseDefault,
            .discardRecording: .default,
            .pauseRecording: .discardDefault,
        ]
        XCTAssertFalse(
            manager.updateHotkeys([
                .toggleRecording: .default,
                .discardRecording: .default,
                .pauseRecording: .pauseDefault,
            ])
        )
        XCTAssertTrue(manager.updateHotkeys(swapped))
        XCTAssertEqual(harness.registerCallCount(), callsBeforeBulk)
        XCTAssertTrue(harness.activeRegistrations().isEmpty)

        manager.resume()
        XCTAssertEqual(harness.activeRegistrations(), swapped)
    }

    @MainActor
    func testHotkeyManagerHandleEventDeduplicatesRepeatsAndClearsHeldActions() {
        let center = NotificationCenter()
        let harness = makeTestHotkeyManager(workspaceNotificationCenter: center)
        let manager = harness.manager
        defer { manager.stop() }

        var triggered: [HotkeyAction] = []
        manager.onTrigger = { triggered.append($0) }
        manager.start()

        let toggleID = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyAction.toggleRecording.rawValue)
        let bogusID = EventHotKeyID(signature: 0x1111_1111, id: HotkeyAction.toggleRecording.rawValue)

        XCTAssertEqual(
            manager.handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), hotKeyID: bogusID),
            OSStatus(eventNotHandledErr)
        )
        XCTAssertEqual(
            manager.handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), hotKeyID: toggleID),
            noErr
        )
        // Auto-repeat while held must not fire a second time.
        XCTAssertEqual(
            manager.handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), hotKeyID: toggleID),
            noErr
        )
        XCTAssertEqual(triggered, [.toggleRecording])

        // Releasing unblocks the next press.
        XCTAssertEqual(
            manager.handleHotKeyEvent(kind: UInt32(kEventHotKeyReleased), hotKeyID: toggleID),
            noErr
        )
        XCTAssertEqual(
            manager.handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), hotKeyID: toggleID),
            noErr
        )
        XCTAssertEqual(triggered, [.toggleRecording, .toggleRecording])

        // clearHeldActions recovers from a dropped release event.
        manager.clearHeldActions()
        XCTAssertEqual(
            manager.handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), hotKeyID: toggleID),
            noErr
        )
        XCTAssertEqual(triggered.count, 3)

        // Session resign and display sleep notifications also clear heldActions.
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertEqual(
            manager.handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), hotKeyID: toggleID),
            noErr
        )
        XCTAssertEqual(triggered.count, 4)

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(
            manager.handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), hotKeyID: toggleID),
            noErr
        )
        XCTAssertEqual(triggered.count, 5)
    }

    @MainActor
    func testHotkeyRecorderViewCancelsAndResumesWhenRemovedFromWindow() {
        let harness = makeTestHotkeyManager()
        let manager = harness.manager
        defer { manager.stop() }
        manager.start()

        let view = HotkeyRecorderView(hotkeyManager: manager)
        var cancelCount = 0
        view.onCancel = { cancelCount += 1 }

        // Removing while not recording should not fire onCancel or touch registrations.
        view.viewWillMove(toWindow: nil)
        XCTAssertEqual(cancelCount, 0)
        XCTAssertEqual(harness.activeRegistrations().count, HotkeyAction.allCases.count)

        view.startRecording()
        XCTAssertTrue(harness.activeRegistrations().isEmpty)

        view.viewWillMove(toWindow: nil)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(harness.activeRegistrations().count, HotkeyAction.allCases.count)
    }
}
