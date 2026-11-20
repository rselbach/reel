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

    @MainActor
    func testRatioLockedResizeAgainstEdgeAlignedAnchorDoesNotCollapse() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let cases: [(CGRect, RegionAdjustment.Handle, CGPoint)] = [
            (CGRect(x: 0, y: 0, width: 160, height: 90), .topRight, CGPoint(x: -200, y: -120)),
            (CGRect(x: 640, y: 0, width: 160, height: 90), .topLeft, CGPoint(x: 200, y: -120)),
            (CGRect(x: 0, y: 510, width: 160, height: 90), .bottomRight, CGPoint(x: -200, y: 120)),
            (CGRect(x: 640, y: 510, width: 160, height: 90), .bottomLeft, CGPoint(x: 200, y: 120)),
            // Anchor near edge with less room than the 16:9 minimum width.
            (CGRect(x: 10, y: 10, width: 160, height: 90), .topRight, CGPoint(x: -200, y: -120)),
        ]

        for (rect, handle, delta) in cases {
            let resized = RegionAdjustment.adjusted(
                rect: rect,
                handle: handle,
                delta: delta,
                bounds: bounds,
                minimumSize: RegionMath.minimumSelectionSize,
                lockedRatio: RegionAspectConstraint.ratio
            )
            XCTAssertGreaterThanOrEqual(resized.width, RegionMath.minimumSelectionSize)
            XCTAssertGreaterThanOrEqual(resized.height, RegionMath.minimumSelectionSize)
            XCTAssertEqual(resized.width / resized.height, RegionAspectConstraint.ratio, accuracy: 0.001)
            XCTAssertTrue(bounds.contains(resized))
        }
    }

    @MainActor
    func testNonRatioLockedResizePreservesAnchoredEdgeWhenDraggedOffScreenOrPastMinimum() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        let topRightOffScreen = RegionAdjustment.adjusted(
            rect: rect,
            handle: .topRight,
            delta: CGPoint(x: 5000, y: 5000),
            bounds: bounds,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(topRightOffScreen, CGRect(x: 100, y: 100, width: 1820, height: 980))

        let bottomLeftOffScreen = RegionAdjustment.adjusted(
            rect: rect,
            handle: .bottomLeft,
            delta: CGPoint(x: -500, y: -500),
            bounds: bounds,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(bottomLeftOffScreen, CGRect(x: 0, y: 0, width: 500, height: 400))

        let topLeftOffScreen = RegionAdjustment.adjusted(
            rect: rect,
            handle: .topLeft,
            delta: CGPoint(x: -500, y: 5000),
            bounds: bounds,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(topLeftOffScreen, CGRect(x: 0, y: 100, width: 500, height: 980))

        let bottomRightOffScreen = RegionAdjustment.adjusted(
            rect: rect,
            handle: .bottomRight,
            delta: CGPoint(x: 5000, y: -500),
            bounds: bounds,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(bottomRightOffScreen, CGRect(x: 100, y: 0, width: 1820, height: 400))

        let topRightPastAnchor = RegionAdjustment.adjusted(
            rect: rect,
            handle: .topRight,
            delta: CGPoint(x: -800, y: -800),
            bounds: bounds,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(topRightPastAnchor, CGRect(x: 100, y: 100, width: 20, height: 20))

        let bottomLeftPastAnchor = RegionAdjustment.adjusted(
            rect: rect,
            handle: .bottomLeft,
            delta: CGPoint(x: 800, y: 800),
            bounds: bounds,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(bottomLeftPastAnchor, CGRect(x: 480, y: 380, width: 20, height: 20))
    }

    @MainActor
    func testSmallSelectionCornerHitTestingResolvesAllFourCornersAndCenter() {
        for side: CGFloat in [20, 24, 28] {
            let rect = CGRect(x: 100, y: 100, width: side, height: side)
            XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: rect.minX, y: rect.minY), in: rect), .bottomLeft)
            XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: rect.maxX, y: rect.minY), in: rect), .bottomRight)
            XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: rect.minX, y: rect.maxY), in: rect), .topLeft)
            XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: rect.maxX, y: rect.maxY), in: rect), .topRight)
            XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: rect.midX, y: rect.midY), in: rect), .move)
            XCTAssertNil(RegionAdjustment.handle(at: CGPoint(x: rect.maxX + 20, y: rect.maxY + 20), in: rect))
        }
    }
}
