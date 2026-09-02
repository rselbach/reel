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
