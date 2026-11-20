import AppKit
import XCTest

@testable import Reel

final class CaptureOverlaysTests: XCTestCase {
    @MainActor
    func testRegionSelectorReturnsNilImmediatelyWhenTaskAlreadyCancelled() async {
        let selector = RegionSelector()
        let task = Task { @MainActor in
            await selector.select()
        }
        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(selector.windows.isEmpty)
    }

    @MainActor
    func testRegionSelectorCancellingInFlightTaskClosesOverlaysAndReturnsNil() async {
        let selector = RegionSelector()
        let task = Task { @MainActor in
            await selector.select()
        }

        // Let select() present its overlay windows before cancelling.
        await Task.yield()
        let presentedWindows = selector.windows
        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(selector.windows.isEmpty)
        for window in presentedWindows {
            XCTAssertFalse(window.isVisible)
        }
    }
}
