@preconcurrency import AVFoundation
import XCTest

@testable import Reel

final class AudioTrackMixerTests: XCTestCase {
    private static let sampleRate = 48_000
    private static let frameRate: Int32 = 30

    func testMixKeepsBothSourcesInOneTrackAndCopiesVideoAndCursor() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Annie-Mix-\(UUID().uuidString).mp4")
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: url.path()) else { return }
            try FileManager.default.removeItem(at: url)
        }
        // The microphone speaks in the first second, the system in the second.
        try await Self.writeFixture(to: url, toneSeconds: [0, 1])
        let tracksBefore = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracksBefore.count, 2)

        try await AudioTrackMixer.mixAudioTracks(at: url)

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2, accuracy: 0.1)

        let loudness = try await Self.loudnessPerSecond(of: try XCTUnwrap(audioTracks.first), in: asset)
        XCTAssertEqual(loudness.count, 2)
        XCTAssertGreaterThan(loudness[0], 0.1, "microphone tone")
        XCTAssertGreaterThan(loudness[1], 0.1, "system tone")

        let cursor = try await CursorMetadataTrack.load(from: url)
        XCTAssertEqual(cursor.samples.count, 60)
        XCTAssertEqual(cursor.samples.first?.time ?? -1, 0, accuracy: 0.001)
    }

    func testRecordingWithOneAudioTrackIsLeftAlone() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Annie-Single-\(UUID().uuidString).mp4")
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: url.path()) else { return }
            try FileManager.default.removeItem(at: url)
        }
        try await Self.writeFixture(to: url, toneSeconds: [0])
        let modified = try FileManager.default.attributesOfItem(atPath: url.path())[.modificationDate] as? Date

        try await AudioTrackMixer.mixAudioTracks(at: url)

        let after = try FileManager.default.attributesOfItem(atPath: url.path())[.modificationDate] as? Date
        XCTAssertEqual(modified, after)
    }

    /// Writes two seconds of video and cursor data plus one audio track per
    /// entry in `toneSeconds`, each holding a tone during that second only.
    private static func writeFixture(to url: URL, toneSeconds: [Int]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 32,
                kCVPixelBufferHeightKey as String: 32,
            ]
        )
        writer.add(videoInput)
        let cursorWriter = try CursorMetadataTrack.Writer(assetWriter: writer, frameRate: Int(frameRate))
        let audioInputs = toneSeconds.map { _ in
            AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ]
            )
        }
        for input in audioInputs {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }

        guard writer.startWriting() else { throw FixtureError.failed(writer.error) }
        let start = CMTime(seconds: 10, preferredTimescale: CMTimeScale(sampleRate))
        writer.startSession(atSourceTime: start)

        // A tenth of a second at a time, video and audio side by side, the
        // way a recording interleaves them.
        let chunk = sampleRate / 10
        for step in 0..<20 {
            for frame in (step * 3)..<(step * 3 + 3) {
                let time = CMTimeAdd(start, CMTime(value: Int64(frame), timescale: frameRate))
                try await waitUntilReady(videoInput)
                guard adaptor.append(try makePixelBuffer(), withPresentationTime: time) else {
                    throw FixtureError.failed(writer.error)
                }
                _ = cursorWriter.append(
                    position: CursorTimeline.Position(x: 0.5, y: 0.5),
                    pressedButtons: 0,
                    at: time
                )
            }
            for (input, toneSecond) in zip(audioInputs, toneSeconds) {
                try await waitUntilReady(input)
                let buffer = try makeAudioBuffer(
                    startFrame: step * chunk,
                    frameCount: chunk,
                    start: start,
                    tone: step / 10 == toneSecond
                )
                guard input.append(buffer) else { throw FixtureError.failed(writer.error) }
            }
        }

        videoInput.markAsFinished()
        cursorWriter.input.markAsFinished()
        for input in audioInputs {
            input.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError.failed(writer.error) }
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 128, CVPixelBufferGetDataSize(pixelBuffer))
        }
        return pixelBuffer
    }

    /// Mono 16-bit PCM: a 440 Hz tone at half scale, or silence.
    private static func makeAudioBuffer(startFrame: Int, frameCount: Int, start: CMTime, tone: Bool) throws
        -> CMSampleBuffer
    {
        let samples: [Int16] = (0..<frameCount).map { index in
            guard tone else { return 0 }
            let phase = 2 * Double.pi * 440 * Double(startFrame + index) / Double(sampleRate)
            return Int16(sin(phase) * 16_000)
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        let byteCount = samples.count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        let blockBuffer = try XCTUnwrap(block)
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: try XCTUnwrap(format),
            sampleCount: frameCount,
            presentationTimeStamp: CMTimeAdd(
                start,
                CMTime(value: Int64(startFrame), timescale: CMTimeScale(sampleRate))
            ),
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        return try XCTUnwrap(sample)
    }

    /// Root-mean-square level of each whole second, from 0 to 1.
    private static func loudnessPerSecond(of track: AVAssetTrack, in asset: AVAsset) async throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        reader.add(output)
        guard reader.startReading() else { throw FixtureError.failed(reader.error) }

        var sums: [Double] = []
        var counts: [Int] = []
        var frame = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var data = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            data.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: bytes.count,
                    destination: bytes.baseAddress!
                )
            }
            for value in data {
                let second = frame / sampleRate
                if second >= sums.count {
                    sums.append(0)
                    counts.append(0)
                }
                let level = Double(value) / Double(Int16.max)
                sums[second] += level * level
                counts[second] += 1
                frame += 1
            }
        }
        return zip(sums, counts)
            .filter { $0.1 > sampleRate / 2 }
            .map { ($0.0 / Double($0.1)).squareRoot() }
    }
}

private enum FixtureError: LocalizedError {
    case failed(Error?)

    var errorDescription: String? {
        switch self {
        case .failed(let error):
            return error?.localizedDescription ?? "The audio mix fixture failed."
        }
    }
}
