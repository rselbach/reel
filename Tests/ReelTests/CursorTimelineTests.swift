@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import XCTest

@testable import Reel

final class CursorTimelineTests: XCTestCase {
    func testTimelineReturnsTheLatestSampleAtOrBeforeSourceTime() {
        let first = CursorTimeline.Sample(
            time: 0,
            position: CursorTimeline.Position(x: 0.1, y: 0.2),
            pressedButtons: 0
        )
        let second = CursorTimeline.Sample(
            time: 1.5,
            position: CursorTimeline.Position(x: 0.8, y: 0.7),
            pressedButtons: 1
        )
        let timeline = CursorTimeline(samples: [first, second])

        XCTAssertNil(timeline.sample(at: -0.1))
        XCTAssertEqual(timeline.sample(at: 0), first)
        XCTAssertEqual(timeline.sample(at: 1.49), first)
        XCTAssertEqual(timeline.sample(at: 1.5), second)
        XCTAssertEqual(timeline.sample(at: 20), second)
    }

    func testFramedWindowCursorPositionUsesFinalVideoCoordinates() throws {
        let frame = FrameCompositor.WindowFrame(
            canvasSize: CGSize(width: 120, height: 80),
            contentOrigin: CGPoint(x: 10, y: 10),
            cornerRadius: 4,
            shadowBlur: 2,
            background: .solid(CIColor.black)
        )

        let position = try XCTUnwrap(
            CursorTimelineLayout.outputPosition(
                contentPosition: CGPoint(x: 0, y: 0),
                contentSize: CGSize(width: 100, height: 60),
                windowFrame: frame
            )
        )

        XCTAssertEqual(position.x, 10.0 / 120.0, accuracy: 0.000_001)
        XCTAssertEqual(position.y, 10.0 / 80.0, accuracy: 0.000_001)
    }

    func testCursorMetadataRoundTripsThroughMP4() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-timeline-\(UUID().uuidString).mp4")
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: outputURL.path()) else { return }
            try FileManager.default.removeItem(at: outputURL)
        }

        try await Self.writeFixture(to: outputURL)
        let timeline = try await CursorMetadataTrack.load(from: outputURL)

        guard timeline.samples.count == 3 else {
            XCTFail("Expected 3 cursor samples, found \(timeline.samples.count)")
            return
        }
        XCTAssertEqual(timeline.samples[0].time, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.samples[0].position?.x ?? -1, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(timeline.samples[0].position?.y ?? -1, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(timeline.samples[0].pressedButtons, 0)

        XCTAssertEqual(timeline.samples[1].time, 1.0 / 30.0, accuracy: 0.001)
        XCTAssertNil(timeline.samples[1].position)
        XCTAssertEqual(timeline.samples[1].pressedButtons, 0)

        XCTAssertEqual(timeline.samples[2].time, 2.0 / 30.0, accuracy: 0.001)
        XCTAssertEqual(timeline.samples[2].position?.x ?? -1, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(timeline.samples[2].position?.y ?? -1, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(timeline.samples[2].pressedButtons, 1)
    }

    func testRapidJitteredTimestampsRoundTripWithoutOverlappingMetadataFailure() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-jitter-\(UUID().uuidString).mp4")
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: outputURL.path()) else { return }
            try FileManager.default.removeItem(at: outputURL)
        }

        let width = 32
        let height = 32
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(videoInput)
        // Frame rate is 30 fps (~33.3ms/frame), while samples arrive 2ms apart.
        let cursorWriter = try CursorMetadataTrack.Writer(assetWriter: writer, frameRate: 30)

        XCTAssertTrue(writer.startWriting())
        let sourceStart = CMTime(value: 10_000, timescale: 1_000)
        writer.startSession(atSourceTime: sourceStart)

        let offsetsMs: [Int64] = [0, 2, 4, 4, 3, 10, 50]
        let expectedOffsetsMs: [Int64] = [0, 2, 4, 10, 50]
        var lastVideoOffset: Int64 = -1
        for (index, offsetMs) in offsetsMs.enumerated() {
            let time = CMTimeAdd(sourceStart, CMTime(value: offsetMs, timescale: 1_000))
            if offsetMs > lastVideoOffset {
                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(1))
                }
                let pixelBuffer = try Self.makePixelBuffer(width: width, height: height)
                XCTAssertTrue(videoAdaptor.append(pixelBuffer, withPresentationTime: time))
                lastVideoOffset = offsetMs
            }
            XCTAssertTrue(
                cursorWriter.append(
                    position: CursorTimeline.Position(x: Double(index) * 0.1, y: 0.5),
                    pressedButtons: UInt64(index % 2),
                    at: time
                )
            )
        }

        videoInput.markAsFinished()
        cursorWriter.input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let timeline = try await CursorMetadataTrack.load(from: outputURL)
        XCTAssertEqual(timeline.samples.count, expectedOffsetsMs.count)
        for (sample, offsetMs) in zip(timeline.samples, expectedOffsetsMs) {
            XCTAssertEqual(sample.time, Double(offsetMs) / 1_000.0, accuracy: 0.002)
        }
    }

    func testFutureMetadataVersionIsSkippedWithoutDecodingError() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-future-version-\(UUID().uuidString).mp4")
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: outputURL.path()) else { return }
            try FileManager.default.removeItem(at: outputURL)
        }

        let width = 32
        let height = 32
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(videoInput)

        func makeGroup(payload: NSDictionary, at time: CMTime) -> AVTimedMetadataGroup {
            let item = AVMutableMetadataItem()
            item.identifier = CursorMetadataTrack.identifier
            item.dataType = kCMMetadataBaseDataType_JSON as String
            item.value = payload
            return AVTimedMetadataGroup(
                items: [item],
                timeRange: CMTimeRange(start: time, duration: .invalid)
            )
        }

        let prototype = makeGroup(payload: ["version": 1] as NSDictionary, at: .zero)
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: try XCTUnwrap(prototype.copyFormatDescription())
        )
        writer.add(metadataInput)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        XCTAssertTrue(writer.startWriting())
        let start = CMTime(value: 0, timescale: 30)
        writer.startSession(atSourceTime: start)

        let payloads: [NSDictionary] = [
            ["version": 1, "position": ["x": 0.2, "y": 0.3], "pressedButtons": 0],
            ["version": 2, "greendaleCursor": ["dx": 42, "campus": "study-room"]],
            ["version": 1, "position": ["x": 0.7, "y": 0.8], "pressedButtons": 1],
        ]
        for (frame, payload) in payloads.enumerated() {
            let time = CMTime(value: Int64(frame), timescale: 30)
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(
                videoAdaptor.append(
                    try Self.makePixelBuffer(width: width, height: height),
                    withPresentationTime: time
                )
            )
            while !metadataInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(metadataAdaptor.append(makeGroup(payload: payload, at: time)))
        }

        videoInput.markAsFinished()
        metadataInput.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let timeline = try await CursorMetadataTrack.load(from: outputURL)
        XCTAssertEqual(timeline.samples.count, 2)
        XCTAssertEqual(timeline.samples[0].position?.x ?? -1, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(timeline.samples[0].pressedButtons, 0)
        XCTAssertEqual(timeline.samples[1].position?.x ?? -1, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(timeline.samples[1].pressedButtons, 1)
    }

    private static func writeFixture(to outputURL: URL) async throws {
        let width = 32
        let height = 32
        let frameRate: Int32 = 30
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw CursorFixtureError.failed("Cannot add video input")
        }
        writer.add(videoInput)
        let cursorWriter = try CursorMetadataTrack.Writer(
            assetWriter: writer,
            frameRate: Int(frameRate)
        )

        guard writer.startWriting() else {
            throw CursorFixtureError.failed(writer.error?.localizedDescription ?? "Cannot start writer")
        }
        let sourceStart = CMTime(seconds: 10, preferredTimescale: frameRate)
        writer.startSession(atSourceTime: sourceStart)

        let positions: [CursorTimeline.Position?] = [
            CursorTimeline.Position(x: 0.1, y: 0.2),
            nil,
            CursorTimeline.Position(x: 0.8, y: 0.9),
        ]
        for (frame, position) in positions.enumerated() {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            let time = CMTimeAdd(sourceStart, CMTime(value: Int64(frame), timescale: frameRate))
            let pixelBuffer = try makePixelBuffer(width: width, height: height)
            guard videoAdaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw CursorFixtureError.failed(writer.error?.localizedDescription ?? "Cannot append video frame")
            }
            guard
                cursorWriter.append(
                    position: position,
                    pressedButtons: frame == 2 ? 1 : 0,
                    at: time
                )
            else {
                throw CursorFixtureError.failed(writer.error?.localizedDescription ?? "Cannot append cursor sample")
            }
        }

        videoInput.markAsFinished()
        cursorWriter.input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CursorFixtureError.failed(writer.error?.localizedDescription ?? "Cannot finish writer")
        }
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
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
            throw CursorFixtureError.failed("Cannot create video frame")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CursorFixtureError.failed("Video frame has no base address")
        }
        memset(address, 0, CVPixelBufferGetDataSize(pixelBuffer))
        return pixelBuffer
    }
}

private enum CursorFixtureError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
