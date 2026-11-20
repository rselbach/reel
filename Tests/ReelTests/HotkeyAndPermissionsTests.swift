import AppKit
import Carbon
import XCTest

@testable import Reel

final class HotkeyAndPermissionsTests: XCTestCase {
    @MainActor
    func testCameraSizeFractionSanitizationHandlesNonFiniteValues() {
        XCTAssertEqual(AppSettings.sanitizedCameraSizeFraction(.nan), AppSettings.CameraOverlaySize.medium.fraction)
        XCTAssertEqual(
            AppSettings.sanitizedCameraSizeFraction(.infinity), AppSettings.CameraOverlaySize.medium.fraction)
        XCTAssertEqual(
            AppSettings.sanitizedCameraSizeFraction(-.infinity), AppSettings.CameraOverlaySize.medium.fraction)
    }

    @MainActor
    func testAssigningNaNCameraSizeFractionFallsBackWithoutRecursing() {
        let settings = AppSettings.shared
        let original = settings.cameraSizeFraction
        defer { settings.cameraSizeFraction = original }

        settings.cameraSizeFraction = .nan
        XCTAssertEqual(settings.cameraSizeFraction, AppSettings.CameraOverlaySize.medium.fraction)

        settings.cameraSizeFraction = .infinity
        XCTAssertEqual(settings.cameraSizeFraction, AppSettings.CameraOverlaySize.medium.fraction)

        settings.cameraSizeFraction = -.infinity
        XCTAssertEqual(settings.cameraSizeFraction, AppSettings.CameraOverlaySize.medium.fraction)
    }
}
