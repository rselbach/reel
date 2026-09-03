import AVFoundation
import CoreGraphics
import CoreImage
import XCTest

@testable import Reel

final class ZoomSceneTests: XCTestCase {
    func testSettingsDefaultsMatchExistingZoomBehavior() throws {
        let settings = ZoomSceneSettings.standard

        XCTAssertEqual(settings.level.scale, 1.5, accuracy: 0.0001)
        XCTAssertEqual(settings.transitionSpeed, .normal)
        XCTAssertEqual(settings.transitionSpeed.duration, 0.25, accuracy: 0.0001)

        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 3))
        let id = try edit.addZoomScene(span: TimelineSpan(start: 1, end: 2))
        XCTAssertEqual(edit.zoomScene(id: id)?.settings, .standard)
    }

    func testZoomLevelClampsToSliderRange() {
        XCTAssertEqual(
            ZoomSceneSettings.Level(scale: 1).scale,
            ZoomSceneSettings.Level.minimumScale,
            accuracy: 0.0001
        )
        XCTAssertEqual(ZoomSceneSettings.Level(scale: 3).label, "300%")
        XCTAssertEqual(
            ZoomSceneSettings.Level(scale: 4).scale,
            ZoomSceneSettings.Level.maximumScale,
            accuracy: 0.0001
        )
        XCTAssertEqual(ZoomSceneSettings.Level(scale: .nan).scale, 1.5, accuracy: 0.0001)
    }

    func testUnitPointRejectsValuesOutsideTheUnitSquare() {
        for tc in [Double.nan, -.infinity, -0.01, 1.01, .infinity] {
            XCTAssertNil(UnitPoint2D(x: tc, y: 0.5), "x \(tc)")
            XCTAssertNil(UnitPoint2D(x: 0.5, y: tc), "y \(tc)")
        }
        XCTAssertEqual(UnitPoint2D(x: 0, y: 1), UnitPoint2D(x: 0, y: 1))
    }

    func testInsertionSortsScenesAndAllowsAdjacency() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let lateID = UUID()
        let firstID = UUID()
        let adjacentID = UUID()

        try edit.addZoomScene(span: TimelineSpan(start: 6, end: 8), id: lateID)
        try edit.addZoomScene(span: TimelineSpan(start: 1, end: 3), id: firstID)
        try edit.addZoomScene(span: TimelineSpan(start: 3, end: 4), id: adjacentID)

        XCTAssertEqual(edit.zoomScenes.map(\.id), [firstID, adjacentID, lateID])
    }

    func testInsertionRejectsDuplicateIdentity() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let id = UUID()
        try edit.addZoomScene(span: TimelineSpan(start: 1, end: 2), id: id)

        XCTAssertThrowsError(
            try edit.addZoomScene(span: TimelineSpan(start: 3, end: 4), id: id)
        ) { error in
            XCTAssertEqual(error as? ZoomSceneEditError, .duplicateID)
        }
    }

    func testInsertionRejectsInvalidAndOverlappingSpans() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        try edit.addZoomScene(span: TimelineSpan(start: 2, end: 4))

        let invalidSpans = [
            TimelineSpan(start: .nan, end: 1),
            TimelineSpan(start: 1, end: .infinity),
            TimelineSpan(start: -1, end: 1),
            TimelineSpan(start: 1, end: 1.2),
            TimelineSpan(start: 8, end: 11),
            TimelineSpan(start: 5, end: 4),
        ]
        for tc in invalidSpans {
            XCTAssertThrowsError(try edit.addZoomScene(span: tc)) { error in
                XCTAssertEqual(error as? ZoomSceneEditError, .invalidSpan)
            }
        }

        for tc in [
            TimelineSpan(start: 1, end: 2.5),
            TimelineSpan(start: 2, end: 3),
            TimelineSpan(start: 3.5, end: 5),
            TimelineSpan(start: 1, end: 5),
        ] {
            XCTAssertThrowsError(try edit.addZoomScene(span: tc)) { error in
                XCTAssertEqual(error as? ZoomSceneEditError, .overlapsExistingScene)
            }
        }
    }

    func testRemovalAndFocalPointUpdate() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let id = try edit.addZoomScene(span: TimelineSpan(start: 2, end: 4))
        let point = try XCTUnwrap(UnitPoint2D(x: 0.2, y: 0.8))

        try edit.setZoomFocalPoint(point, for: id)
        XCTAssertEqual(edit.zoomScene(id: id)?.focalPoint, point)
        XCTAssertThrowsError(try edit.setZoomFocalPoint(point, for: UUID())) { error in
            XCTAssertEqual(error as? ZoomSceneEditError, .sceneNotFound)
        }

        edit.removeZoomScene(id: id)
        XCTAssertTrue(edit.zoomScenes.isEmpty)
    }

    func testSettingsUpdateAndMissingScene() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let id = try edit.addZoomScene(span: TimelineSpan(start: 2, end: 4))
        let settings = ZoomSceneSettings(
            level: ZoomSceneSettings.Level(scale: 2),
            transitionSpeed: .slow
        )

        try edit.setZoomSettings(settings, for: id)
        XCTAssertEqual(edit.zoomScene(id: id)?.settings, settings)
        XCTAssertThrowsError(try edit.setZoomSettings(settings, for: UUID())) { error in
            XCTAssertEqual(error as? ZoomSceneEditError, .sceneNotFound)
        }
    }

    func testResizeKeepsIdentityFocalPointAndSettings() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let point = try XCTUnwrap(UnitPoint2D(x: 0.2, y: 0.8))
        let settings = ZoomSceneSettings(
            level: ZoomSceneSettings.Level(scale: 1.75),
            transitionSpeed: .fast
        )
        let id = try edit.addZoomScene(
            span: TimelineSpan(start: 2, end: 4),
            focalPoint: point,
            settings: settings
        )

        try edit.resizeZoomScene(id: id, to: TimelineSpan(start: 1, end: 6))

        XCTAssertEqual(
            edit.zoomScene(id: id),
            ZoomScene(
                id: id,
                span: TimelineSpan(start: 1, end: 6),
                focalPoint: point,
                settings: settings
            )
        )
    }

    func testResizeBoundsStopAtAdjacentScenesAndRecordingEdges() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let firstID = try edit.addZoomScene(span: TimelineSpan(start: 1, end: 2))
        let middleID = try edit.addZoomScene(span: TimelineSpan(start: 4, end: 6))
        let lastID = try edit.addZoomScene(span: TimelineSpan(start: 8, end: 9))

        XCTAssertEqual(
            edit.zoomSceneResizeBounds(id: firstID),
            TimelineSpan(start: 0, end: 4)
        )
        XCTAssertEqual(
            edit.zoomSceneResizeBounds(id: middleID),
            TimelineSpan(start: 2, end: 8)
        )
        XCTAssertEqual(
            edit.zoomSceneResizeBounds(id: lastID),
            TimelineSpan(start: 6, end: 10)
        )
        XCTAssertNil(edit.zoomSceneResizeBounds(id: UUID()))
    }

    func testResizeRejectsInvalidOverlapAndMissingScene() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let firstID = try edit.addZoomScene(span: TimelineSpan(start: 1, end: 3))
        let secondID = try edit.addZoomScene(span: TimelineSpan(start: 5, end: 7))

        XCTAssertThrowsError(
            try edit.resizeZoomScene(
                id: secondID,
                to: TimelineSpan(start: 2, end: 6)
            )
        ) { error in
            XCTAssertEqual(error as? ZoomSceneEditError, .overlapsExistingScene)
        }
        XCTAssertThrowsError(
            try edit.resizeZoomScene(
                id: firstID,
                to: TimelineSpan(start: 2, end: 2.2)
            )
        ) { error in
            XCTAssertEqual(error as? ZoomSceneEditError, .invalidSpan)
        }
        XCTAssertThrowsError(
            try edit.resizeZoomScene(
                id: UUID(),
                to: TimelineSpan(start: 2, end: 4)
            )
        ) { error in
            XCTAssertEqual(error as? ZoomSceneEditError, .sceneNotFound)
        }
    }

    func testLookupUsesHalfOpenSceneBoundaries() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let firstID = try edit.addZoomScene(span: TimelineSpan(start: 2, end: 4))
        let secondID = try edit.addZoomScene(span: TimelineSpan(start: 4, end: 6))

        XCTAssertNil(edit.zoomScene(atSourceTime: 1.999))
        XCTAssertEqual(edit.zoomScene(atSourceTime: 2)?.id, firstID)
        XCTAssertEqual(edit.zoomScene(atSourceTime: 3.999)?.id, firstID)
        XCTAssertEqual(edit.zoomScene(atSourceTime: 4)?.id, secondID)
        XCTAssertNil(edit.zoomScene(atSourceTime: 6))
        XCTAssertNil(edit.zoomScene(atSourceTime: .nan))
    }

    func testAvailableSpanReturnsOnlyTheContainingGap() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        try edit.addZoomScene(span: TimelineSpan(start: 2, end: 4))
        try edit.addZoomScene(span: TimelineSpan(start: 6, end: 8))

        XCTAssertEqual(edit.availableZoomSpan(containing: 1), TimelineSpan(start: 0, end: 2))
        XCTAssertNil(edit.availableZoomSpan(containing: 3))
        XCTAssertEqual(edit.availableZoomSpan(containing: 5), TimelineSpan(start: 4, end: 6))
        XCTAssertEqual(edit.availableZoomSpan(containing: 9), TimelineSpan(start: 8, end: 10))
    }

    func testZoomScenesRemainUnchangedWhenClipsAreDeleted() throws {
        let clipID = UUID()
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10, initialClipID: clipID))
        let sceneID = try edit.addZoomScene(span: TimelineSpan(start: 2, end: 8))
        XCTAssertNotNil(edit.splitClip(at: 3))
        XCTAssertNotNil(edit.splitClip(at: 7))
        XCTAssertTrue(edit.deleteClip(id: try XCTUnwrap(edit.clipID(at: 4))))

        XCTAssertEqual(edit.zoomScene(id: sceneID)?.span, TimelineSpan(start: 2, end: 8))
    }

    func testZoomOnlyEditIsMeaningful() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        XCTAssertFalse(edit.hasMeaningfulChanges)
        let id = try edit.addZoomScene(span: TimelineSpan(start: 2, end: 4))
        XCTAssertTrue(edit.hasMeaningfulChanges)
        edit.removeZoomScene(id: id)
        XCTAssertFalse(edit.hasMeaningfulChanges)
    }

    func testSelectionValidatesZoomSceneIdentity() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let id = try edit.addZoomScene(span: TimelineSpan(start: 2, end: 4))

        XCTAssertEqual(TimelineSelection.zoomScene(id).validated(for: edit), .zoomScene(id))
        XCTAssertEqual(TimelineSelection.zoomScene(UUID()).validated(for: edit), .none)
        edit.removeZoomScene(id: id)
        XCTAssertEqual(TimelineSelection.zoomScene(id).validated(for: edit), .none)
    }

    func testLayoutCentersCropAndPinsItAtCorners() throws {
        let sourceSize = CGSize(width: 300, height: 180)
        let cases: [UnitPoint2D: CGRect] = [
            .center: CGRect(x: 50, y: 30, width: 200, height: 120),
            try XCTUnwrap(UnitPoint2D(x: 0, y: 0)): CGRect(x: 0, y: 0, width: 200, height: 120),
            try XCTUnwrap(UnitPoint2D(x: 1, y: 0)): CGRect(x: 100, y: 0, width: 200, height: 120),
            try XCTUnwrap(UnitPoint2D(x: 0, y: 1)): CGRect(x: 0, y: 60, width: 200, height: 120),
            try XCTUnwrap(UnitPoint2D(x: 1, y: 1)): CGRect(x: 100, y: 60, width: 200, height: 120),
        ]

        for (tc, want) in cases {
            let layout = try XCTUnwrap(
                ZoomLayout.resolve(
                    sourceSize: sourceSize,
                    focalPoint: tc,
                    scale: ZoomSceneSettings.standard.level.scale
                )
            )
            XCTAssertEqual(layout.sourceCropRect, want)
            XCTAssertEqual(layout.requestedFocalPoint, CGPoint(x: sourceSize.width * tc.x, y: sourceSize.height * tc.y))
        }
    }

    func testLayoutRejectsInvalidSizesAndScales() {
        XCTAssertNil(
            ZoomLayout.resolve(
                sourceSize: .zero,
                focalPoint: .center,
                scale: ZoomSceneSettings.standard.level.scale
            )
        )
        XCTAssertNil(
            ZoomLayout.resolve(
                sourceSize: CGSize(width: CGFloat.infinity, height: 100),
                focalPoint: .center,
                scale: ZoomSceneSettings.standard.level.scale
            )
        )
        XCTAssertNil(
            ZoomLayout.resolve(
                sourceSize: CGSize(width: 100, height: 100),
                focalPoint: .center,
                scale: 0
            )
        )
    }

    func testFocalPointMappingRemovesAspectFitOrigin() throws {
        let contentRect = CGRect(x: 100, y: 40, width: 400, height: 200)
        let point = try XCTUnwrap(
            ZoomFocusGeometry.focalPoint(
                at: CGPoint(x: 300, y: 90),
                in: contentRect
            )
        )

        XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.75, accuracy: 0.0001)
    }

    func testCompactedScheduleIntersectsScenesWithKeptRanges() throws {
        let firstClipID = UUID()
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 6, initialClipID: firstClipID))
        let middleClipID = try XCTUnwrap(edit.splitClip(at: 2))
        XCTAssertNotNil(edit.splitClip(at: 4))
        XCTAssertTrue(edit.deleteClip(id: middleClipID))
        let focalPoint = try XCTUnwrap(UnitPoint2D(x: 0.2, y: 0.8))
        let settings = ZoomSceneSettings(
            level: ZoomSceneSettings.Level(scale: 1.75),
            transitionSpeed: .slow
        )
        try edit.addZoomScene(
            span: TimelineSpan(start: 1, end: 5),
            focalPoint: focalPoint,
            settings: settings
        )

        let schedule = ZoomVideoComposition.compactedSchedule(edit: edit)
        XCTAssertEqual(
            schedule,
            [
                ZoomRenderScene(
                    span: TimelineSpan(start: 1, end: 2),
                    sourceSceneSpan: TimelineSpan(start: 1, end: 5),
                    sourceTimeAtStart: 1,
                    focalPoint: focalPoint,
                    settings: settings
                ),
                ZoomRenderScene(
                    span: TimelineSpan(start: 2, end: 3),
                    sourceSceneSpan: TimelineSpan(start: 1, end: 5),
                    sourceTimeAtStart: 4,
                    focalPoint: focalPoint,
                    settings: settings
                ),
            ]
        )
        XCTAssertEqual(schedule[1].sourceTime(at: 2.875), 4.875, accuracy: 0.0001)
    }

    func testTransitionEasesInAndOut() throws {
        let point = try XCTUnwrap(UnitPoint2D(x: 0.2, y: 0.8))
        let span = TimelineSpan(start: 1, end: 2)

        XCTAssertNil(
            ZoomTransition.state(
                at: 0.999,
                sceneSpan: span,
                focalPoint: point,
                settings: .standard
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: .standard
                )
            ).scale,
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1.125,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: .standard
                )
            ).scale,
            1.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1.25,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: .standard
                )
            ).scale,
            1.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1.875,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: .standard
                )
            ).scale,
            1.25,
            accuracy: 0.0001
        )
        XCTAssertNil(
            ZoomTransition.state(
                at: 2,
                sceneSpan: span,
                focalPoint: point,
                settings: .standard
            )
        )
    }

    func testCustomLevelAndSpeedChangeTransition() throws {
        let point = try XCTUnwrap(UnitPoint2D(x: 0.2, y: 0.8))
        let span = TimelineSpan(start: 1, end: 2)
        let settings = ZoomSceneSettings(
            level: ZoomSceneSettings.Level(scale: 2),
            transitionSpeed: .fast
        )

        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1.075,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: settings
                )
            ).scale,
            1.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1.15,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: settings
                )
            ).scale,
            2,
            accuracy: 0.0001
        )
    }

    func testShortTransitionReachesFullZoomAtItsMidpoint() throws {
        let point = try XCTUnwrap(UnitPoint2D(x: 0.2, y: 0.8))
        let span = TimelineSpan(start: 1, end: 1.25)

        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1.0625,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: ZoomSceneSettings(
                        level: ZoomSceneSettings.Level(scale: 1.5),
                        transitionSpeed: .slow
                    )
                )
            ).scale,
            1.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1.125,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: ZoomSceneSettings(
                        level: ZoomSceneSettings.Level(scale: 1.5),
                        transitionSpeed: .slow
                    )
                )
            ).scale,
            1.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ZoomTransition.state(
                    at: 1.1875,
                    sceneSpan: span,
                    focalPoint: point,
                    settings: ZoomSceneSettings(
                        level: ZoomSceneSettings.Level(scale: 1.5),
                        transitionSpeed: .slow
                    )
                )
            ).scale,
            1.25,
            accuracy: 0.0001
        )
    }

    func testSourceTimeRendererUsesCustomZoomLevel() throws {
        let image = Self.stripedImage(width: 300, height: 180)
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 3))
        try edit.addZoomScene(
            span: TimelineSpan(start: 1, end: 2),
            focalPoint: try XCTUnwrap(UnitPoint2D(x: 0, y: 0.5)),
            settings: ZoomSceneSettings(
                level: ZoomSceneSettings.Level(scale: 2),
                transitionSpeed: .fast
            )
        )

        let rendered = ZoomImageRenderer.render(image, sourceTime: 1.5, scenes: edit.zoomScenes)

        XCTAssertEqual(try Self.sampledColor(from: rendered, normalizedX: 0.6), .red)
    }

    func testSharedImageRendererAnimatesAtHalfOpenSceneBoundaries() throws {
        let image = Self.stripedImage(width: 300, height: 180)
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 3))
        try edit.addZoomScene(
            span: TimelineSpan(start: 1, end: 2),
            focalPoint: try XCTUnwrap(UnitPoint2D(x: 0, y: 0.5))
        )

        let before = ZoomImageRenderer.render(image, sourceTime: 0.999, scenes: edit.zoomScenes)
        let entering = ZoomImageRenderer.render(image, sourceTime: 1, scenes: edit.zoomScenes)
        let inside = ZoomImageRenderer.render(image, sourceTime: 1.25, scenes: edit.zoomScenes)
        let exiting = ZoomImageRenderer.render(image, sourceTime: 1.875, scenes: edit.zoomScenes)
        let after = ZoomImageRenderer.render(image, sourceTime: 2, scenes: edit.zoomScenes)

        XCTAssertEqual(try Self.sampledColor(from: before, normalizedX: 0.8), .blue)
        XCTAssertEqual(try Self.sampledColor(from: entering, normalizedX: 0.8), .blue)
        XCTAssertEqual(try Self.sampledColor(from: inside, normalizedX: 0.8), .green)
        XCTAssertEqual(try Self.sampledColor(from: exiting, normalizedX: 0.8), .green)
        XCTAssertEqual(try Self.sampledColor(from: after, normalizedX: 0.8), .blue)
    }

    @MainActor
    func testMP4ExportsApplyZoomBeforeInsideAndAfterScene() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Greendale-Zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove zoom fixture directory: \(error)")
            }
        }

        let sourceURL = directory.appendingPathComponent("Greendale-zoom-source.mp4")
        try await Self.writeStripedFixture(to: sourceURL)
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 3))
        try edit.addZoomScene(
            span: TimelineSpan(start: 1, end: 2),
            focalPoint: try XCTUnwrap(UnitPoint2D(x: 0, y: 0.5))
        )

        let cases: [String: VideoExportQuality] = [
            "source": .source,
            "720p": .p720,
        ]
        for (name, quality) in cases {
            let outputURL = directory.appendingPathComponent("Greendale-zoom-export-\(name).mp4")
            try await VideoEditExporter.export(
                sourceURL: sourceURL,
                outputURL: outputURL,
                quality: quality,
                edit: edit
            )

            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let before = try await Self.sampledColor(from: generator, at: 0.5, normalizedX: 0.8)
            let enteringStart = try await Self.sampledColor(from: generator, at: 1, normalizedX: 0.8)
            let entering = try await Self.sampledColor(
                from: generator,
                at: 34.0 / 30.0,
                normalizedX: 0.8
            )
            let inside = try await Self.sampledColor(from: generator, at: 1.5, normalizedX: 0.8)
            let exiting = try await Self.sampledColor(
                from: generator,
                at: 56.0 / 30.0,
                normalizedX: 0.8
            )
            let after = try await Self.sampledColor(from: generator, at: 2.5, normalizedX: 0.8)
            XCTAssertTrue(before.isBlue, "\(name): \(before)")
            XCTAssertTrue(enteringStart.isBlue, "\(name): \(enteringStart)")
            XCTAssertTrue(entering.isGreen, "\(name): \(entering)")
            XCTAssertTrue(inside.isGreen, "\(name): \(inside)")
            XCTAssertTrue(exiting.isGreen, "\(name): \(exiting)")
            XCTAssertTrue(after.isBlue, "\(name): \(after)")
        }
    }

    private static func stripedImage(width: Int, height: Int) -> CIImage {
        let third = CGFloat(width) / 3
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let red = CIImage(color: CIColor.red).cropped(
            to: CGRect(x: 0, y: 0, width: third, height: CGFloat(height))
        )
        let green = CIImage(color: CIColor.green).cropped(
            to: CGRect(x: third, y: 0, width: third, height: CGFloat(height))
        )
        let blue = CIImage(color: CIColor.blue).cropped(
            to: CGRect(x: third * 2, y: 0, width: third, height: CGFloat(height))
        )
        return red.composited(over: green.composited(over: blue)).cropped(to: extent)
    }

    private static func writeStripedFixture(to outputURL: URL) async throws {
        let width = 300
        let height = 180
        let frameRate: Int32 = 30
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30],
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw ZoomFixtureError.failed("Cannot add zoom fixture video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ZoomFixtureError.failed(writer.error?.localizedDescription ?? "Cannot start zoom fixture writer")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            let pixelBuffer = try makeStripedPixelBuffer(width: width, height: height)
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: frameRate))
            else {
                throw ZoomFixtureError.failed(writer.error?.localizedDescription ?? "Cannot append zoom fixture frame")
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ZoomFixtureError.failed(writer.error?.localizedDescription ?? "Cannot finish zoom fixture writer")
        }
    }

    private static func makeStripedPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ZoomFixtureError.failed("Cannot create zoom fixture pixel buffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ZoomFixtureError.failed("Zoom fixture pixel buffer has no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                let color: ZoomFixtureColor
                switch column {
                case 0..<(width / 3):
                    color = .red
                case (width / 3)..<(width * 2 / 3):
                    color = .green
                default:
                    color = .blue
                }
                let offset = row * bytesPerRow + column * 4
                bytes[offset] = color.blue
                bytes[offset + 1] = color.green
                bytes[offset + 2] = color.red
                bytes[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    private static func sampledColor(
        from generator: AVAssetImageGenerator,
        at seconds: Double,
        normalizedX: Double
    ) async throws -> ZoomFixtureColor {
        let frame = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)
        ).image
        guard
            let pixel = frame.cropping(
                to: CGRect(
                    x: Int(Double(frame.width - 1) * normalizedX),
                    y: frame.height / 2,
                    width: 1,
                    height: 1
                )
            )
        else {
            throw ZoomFixtureError.failed("Cannot crop exported fixture pixel")
        }
        return try sampledColor(from: CIImage(cgImage: pixel), normalizedX: 0.5)
    }

    private static func sampledColor(
        from image: CIImage,
        normalizedX: Double
    ) throws -> ZoomFixtureColor {
        let context = CIContext(options: [.cacheIntermediates: false])
        let point = CGPoint(
            x: image.extent.minX + image.extent.width * normalizedX,
            y: image.extent.midY
        )
        let rect = CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)
        guard let pixel = context.createCGImage(image, from: rect) else {
            throw ZoomFixtureError.failed("Cannot render fixture pixel")
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                throw ZoomFixtureError.failed("Cannot create fixture color context")
            }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return ZoomFixtureColor(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
}

private struct ZoomFixtureColor: Equatable, Sendable {
    static let red = ZoomFixtureColor(red: 255, green: 0, blue: 0)
    static let green = ZoomFixtureColor(red: 0, green: 255, blue: 0)
    static let blue = ZoomFixtureColor(red: 0, green: 0, blue: 255)

    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var isBlue: Bool {
        Int(blue) > Int(red) + 100 && Int(blue) > Int(green) + 100
    }

    var isGreen: Bool {
        Int(green) > Int(red) + 100 && Int(green) > Int(blue) + 100
    }
}

private enum ZoomFixtureError: LocalizedError, Sendable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
