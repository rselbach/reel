import XCTest
@testable import Reel

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testCameraOverlayPositionNormalizedCoordinates() {
        XCTAssertEqual(AppSettings.CameraOverlayPosition.bottomLeft.normalizedCoordinates.x, 0.0)
        XCTAssertEqual(AppSettings.CameraOverlayPosition.bottomLeft.normalizedCoordinates.y, 0.0)

        XCTAssertEqual(AppSettings.CameraOverlayPosition.topRight.normalizedCoordinates.x, 1.0)
        XCTAssertEqual(AppSettings.CameraOverlayPosition.topRight.normalizedCoordinates.y, 1.0)
    }

    @MainActor
    func testVideoQualityBitrates() {
        XCTAssertEqual(AppSettings.VideoQuality.low.bitrate, 5_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.medium.bitrate, 10_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.high.bitrate, 20_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.maximum.bitrate, 50_000_000)
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
    func testFrameRateSanitizationUsesSafeFallback() {
        XCTAssertEqual(AppSettings.sanitizedFrameRate(0), 60)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(30), 30)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(60), 60)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(45), 30)
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
}
