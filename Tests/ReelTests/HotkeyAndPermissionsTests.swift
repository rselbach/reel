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
}
