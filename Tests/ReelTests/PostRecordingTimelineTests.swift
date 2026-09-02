import AVFoundation
import CoreGraphics
import XCTest

@testable import Reel

final class PostRecordingTimelineTests: XCTestCase {
    func testRejectsInvalidSourceDurations() {
        for tc in [0.0, -1, .infinity, .nan] {
            XCTAssertNil(TimelineEdit(sourceDuration: tc))
        }
    }

    func testSplitsClipsInSourceOrderWithoutChangingOutput() throws {
        let initialID = UUID()
        let middleID = UUID()
        let finalID = UUID()
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 12, initialClipID: initialID))

        XCTAssertEqual(edit.splitClip(at: 8, rightClipID: finalID), finalID)
        XCTAssertEqual(edit.splitClip(at: 2, rightClipID: middleID), middleID)

        XCTAssertEqual(edit.clips.map(\.id), [initialID, middleID, finalID])
        XCTAssertEqual(
            edit.clips.map(\.span),
            [
                TimelineSpan(start: 0, end: 2),
                TimelineSpan(start: 2, end: 8),
                TimelineSpan(start: 8, end: 12),
            ]
        )
        XCTAssertEqual(edit.keptRanges, [TimelineSpan(start: 0, end: 12)])
        XCTAssertFalse(edit.hasMeaningfulChanges)
    }

    func testRejectsInvalidSplitsAndSplitsInsideDeletedClips() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let middleID = try XCTUnwrap(edit.splitClip(at: 4))
        XCTAssertNotNil(edit.splitClip(at: 6))
        XCTAssertTrue(edit.deleteClip(id: middleID))

        for tc in [Double.nan, -1, 0, 4, 4.01, 10, 11] {
            XCTAssertNil(edit.splitClip(at: tc), "time \(tc)")
        }
    }

    func testDeletingSplitClipsHandlesStartMiddleAndEndEdits() throws {
        let startID = UUID()
        let middleID = UUID()
        let endID = UUID()

        var startEdit = try makeThreeClipEdit(
            initialID: startID,
            middleID: middleID,
            endID: endID
        )
        XCTAssertTrue(startEdit.deleteClip(id: startID))
        XCTAssertEqual(startEdit.keptRanges, [TimelineSpan(start: 2, end: 10)])

        var middleEdit = try makeThreeClipEdit(
            initialID: startID,
            middleID: middleID,
            endID: endID
        )
        XCTAssertTrue(middleEdit.deleteClip(id: middleID))
        XCTAssertEqual(
            middleEdit.keptRanges,
            [TimelineSpan(start: 0, end: 2), TimelineSpan(start: 8, end: 10)]
        )

        var endEdit = try makeThreeClipEdit(
            initialID: startID,
            middleID: middleID,
            endID: endID
        )
        XCTAssertTrue(endEdit.deleteClip(id: endID))
        XCTAssertEqual(endEdit.keptRanges, [TimelineSpan(start: 0, end: 8)])
    }

    func testRestoresOnlySelectedDeletedClip() throws {
        let startID = UUID()
        let middleID = UUID()
        let endID = UUID()
        var edit = try makeThreeClipEdit(
            initialID: startID,
            middleID: middleID,
            endID: endID
        )
        XCTAssertTrue(edit.deleteClip(id: startID))
        XCTAssertTrue(edit.deleteClip(id: endID))

        edit.restoreClip(id: startID)

        XCTAssertEqual(edit.deletedClips.map(\.id), [endID])
        XCTAssertEqual(edit.keptRanges, [TimelineSpan(start: 0, end: 8)])
    }

    func testRejectsDeletingTheLastRetainedClip() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let rightID = try XCTUnwrap(edit.splitClip(at: 5))
        let leftID = try XCTUnwrap(edit.clips.first?.id)

        XCTAssertTrue(edit.deleteClip(id: leftID))
        XCTAssertFalse(edit.deleteClip(id: rightID))
        XCTAssertEqual(edit.editedDuration, 5)
    }

    func testMappingsCrossDeletedClipBoundaries() throws {
        let initialID = UUID()
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10, initialClipID: initialID))
        let clipFromOne = try XCTUnwrap(edit.splitClip(at: 1))
        let clipFromThree = try XCTUnwrap(edit.splitClip(at: 3))
        let clipFromFive = try XCTUnwrap(edit.splitClip(at: 5))
        let clipFromNine = try XCTUnwrap(edit.splitClip(at: 9))
        XCTAssertTrue(edit.deleteClip(id: initialID))
        XCTAssertTrue(edit.deleteClip(id: clipFromThree))
        XCTAssertTrue(edit.deleteClip(id: clipFromNine))

        let editedToSource: [Double: Double] = [0: 1, 1.5: 2.5, 2: 5, 6: 9]
        for (tc, want) in editedToSource {
            XCTAssertEqual(try XCTUnwrap(edit.sourceTime(forEditedTime: tc)), want, accuracy: 0.0001)
        }

        let sourceToEdited: [Double: Double] = [1: 0, 2.5: 1.5, 5: 2, 9: 6]
        for (tc, want) in sourceToEdited {
            XCTAssertEqual(try XCTUnwrap(edit.editedTime(forSourceTime: tc)), want, accuracy: 0.0001)
        }
        XCTAssertNil(edit.editedTime(forSourceTime: 3))
        XCTAssertNil(edit.editedTime(forSourceTime: 4))
        XCTAssertEqual(edit.playableSourceTime(atOrAfter: 0), 1)
        XCTAssertEqual(edit.playableSourceTime(atOrAfter: 4), 5)
        XCTAssertNil(edit.playableSourceTime(atOrAfter: 9.1))
        XCTAssertEqual(edit.clipID(at: 1), clipFromOne)
        XCTAssertEqual(edit.clipID(at: 5), clipFromFive)
    }

    func testTimelineGeometryMapsSourceTimeAndDragDistance() {
        XCTAssertEqual(
            PostRecordingTimelineMath.position(for: 2.5, duration: 10, width: 400),
            100
        )
        XCTAssertEqual(
            PostRecordingTimelineMath.sourceTime(at: 500, duration: 10, width: 400),
            10
        )
        XCTAssertEqual(
            PostRecordingTimelineMath.translatedSourceTime(
                origin: 4,
                translation: -80,
                duration: 10,
                width: 400
            ),
            2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PostRecordingTimelineMath.width(
                for: TimelineSpan(start: 2, end: 5),
                duration: 10,
                width: 400
            ),
            120
        )
    }

    func testTimelineThumbnailCountAndSampleTimesFollowQuantizedWidth() {
        XCTAssertEqual(PostRecordingTimelineMath.thumbnailCount(forWidth: 200), 3)
        XCTAssertEqual(PostRecordingTimelineMath.thumbnailCount(forWidth: 288), 3)
        XCTAssertEqual(PostRecordingTimelineMath.thumbnailCount(forWidth: 289), 4)
        XCTAssertEqual(PostRecordingTimelineMath.thumbnailCount(forWidth: 10_000), 24)
        XCTAssertEqual(
            PostRecordingTimelineMath.thumbnailSampleTimes(duration: 12, count: 4),
            [1.5, 4.5, 7.5, 10.5]
        )
        XCTAssertEqual(PostRecordingTimelineMath.thumbnailSampleTimes(duration: 12, count: 0), [])
        XCTAssertEqual(PostRecordingTimelineMath.formattedTime(65.49), "1:05.4")
        XCTAssertEqual(PostRecordingTimelineMath.formattedTime(.nan), "0:00.0")
    }

    func testEditedTimeSkipsDeletedClipsAndClampsToTheEdit() throws {
        let initialID = UUID()
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 20, initialClipID: initialID))
        XCTAssertNotNil(edit.splitClip(at: 1))
        let deletedMiddleID = try XCTUnwrap(edit.splitClip(at: 5))
        XCTAssertNotNil(edit.splitClip(at: 10))
        let deletedEndID = try XCTUnwrap(edit.splitClip(at: 19))
        XCTAssertTrue(edit.deleteClip(id: initialID))
        XCTAssertTrue(edit.deleteClip(id: deletedMiddleID))
        XCTAssertTrue(edit.deleteClip(id: deletedEndID))

        XCTAssertEqual(
            try XCTUnwrap(
                PostRecordingTimelineMath.sourceTimeBySkipping(
                    fromSourceTime: 4,
                    seconds: 3,
                    edit: edit
                )),
            12,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                PostRecordingTimelineMath.sourceTimeBySkipping(
                    fromSourceTime: 11,
                    seconds: -3,
                    edit: edit
                )),
            3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                PostRecordingTimelineMath.sourceTimeBySkipping(
                    fromSourceTime: 1,
                    seconds: -5,
                    edit: edit
                )),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                PostRecordingTimelineMath.sourceTimeBySkipping(
                    fromSourceTime: 18,
                    seconds: 5,
                    edit: edit
                )),
            19,
            accuracy: 0.0001
        )
    }

    func testTimelineSelectionTracksExistingClips() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let clipID = try XCTUnwrap(edit.splitClip(at: 4))

        XCTAssertEqual(TimelineSelection.clip(clipID).validated(for: edit), .clip(clipID))
        XCTAssertTrue(edit.deleteClip(id: clipID))
        XCTAssertEqual(TimelineSelection.clip(clipID).validated(for: edit), .clip(clipID))
        XCTAssertEqual(TimelineSelection.clip(UUID()).validated(for: edit), .none)
    }

    func testMeaningfulChangeTracksDeletedClipsButNotSplits() throws {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let clipID = try XCTUnwrap(edit.splitClip(at: 4))

        XCTAssertFalse(edit.hasMeaningfulChanges)
        XCTAssertTrue(edit.deleteClip(id: clipID))
        XCTAssertTrue(edit.hasMeaningfulChanges)
        edit.restoreClip(id: clipID)
        XCTAssertFalse(edit.hasMeaningfulChanges)
    }

    @MainActor
    func testVideoExporterJoinsKeptRangesInOrderForBothPresets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Troy-Middle-Cut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove video export fixture: \(error)")
            }
        }

        let sourceURL = directory.appendingPathComponent("Greendale-source.mp4")
        try await Self.writeColorFixture(to: sourceURL)

        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 3))
        let middleID = try XCTUnwrap(edit.splitClip(at: 0.75))
        XCTAssertNotNil(edit.splitClip(at: 2.25))
        XCTAssertTrue(edit.deleteClip(id: middleID))

        let cases = [
            "passthrough": VideoExportQuality.source,
            "720p": VideoExportQuality.p720,
        ]
        for (name, quality) in cases {
            let outputURL = directory.appendingPathComponent("Greendale-edited-\(name).mp4")
            try await VideoEditExporter.export(
                sourceURL: sourceURL,
                outputURL: outputURL,
                quality: quality,
                edit: edit
            )

            let asset = AVURLAsset(url: outputURL)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            XCTAssertEqual(duration, 1.5, accuracy: 0.1, name)

            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let first = try await Self.sampledColor(from: generator, at: 0.25)
            let second = try await Self.sampledColor(from: generator, at: 1)
            XCTAssertGreaterThan(Int(first.red), Int(first.blue) + 40, name)
            XCTAssertGreaterThan(Int(second.blue), Int(second.red) + 40, name)
        }
    }

    private func makeThreeClipEdit(
        initialID: UUID,
        middleID: UUID,
        endID: UUID
    ) throws -> TimelineEdit {
        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10, initialClipID: initialID))
        XCTAssertEqual(edit.splitClip(at: 8, rightClipID: endID), endID)
        XCTAssertEqual(edit.splitClip(at: 2, rightClipID: middleID), middleID)
        return edit
    }

    private static func writeColorFixture(to outputURL: URL) async throws {
        let width = 96
        let height = 54
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
            throw VideoFixtureError.failed("Cannot add fixture video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoFixtureError.failed(writer.error?.localizedDescription ?? "Cannot start fixture writer")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            let color: FixtureColor
            switch frame {
            case 0..<30:
                color = FixtureColor(red: 255, green: 0, blue: 0)
            case 30..<60:
                color = FixtureColor(red: 0, green: 255, blue: 0)
            default:
                color = FixtureColor(red: 0, green: 0, blue: 255)
            }
            let pixelBuffer = try makePixelBuffer(width: width, height: height, color: color)
            let time = CMTime(value: Int64(frame), timescale: frameRate)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw VideoFixtureError.failed(writer.error?.localizedDescription ?? "Cannot append fixture frame")
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoFixtureError.failed(writer.error?.localizedDescription ?? "Cannot finish fixture writer")
        }
    }

    private static func makePixelBuffer(width: Int, height: Int, color: FixtureColor) throws -> CVPixelBuffer {
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
            throw VideoFixtureError.failed("Cannot create fixture pixel buffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VideoFixtureError.failed("Fixture pixel buffer has no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * bytesPerRow + column * 4
                bytes[offset] = color.blue
                bytes[offset + 1] = color.green
                bytes[offset + 2] = color.red
                bytes[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    private static func sampledColor(from generator: AVAssetImageGenerator, at seconds: Double) async throws
        -> FixtureColor
    {
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                throw VideoFixtureError.failed("Cannot create fixture color context")
            }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return FixtureColor(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
}

private struct FixtureColor: Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

private enum VideoFixtureError: LocalizedError, Sendable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
