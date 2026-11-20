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

    func testPipeCompletesWithoutHangingWhenReaderIsCancelled() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Troy-ReaderCancel-\(UUID().uuidString).mp4")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Troy-ReaderCancelOut-\(UUID().uuidString).mp4")
        addTeardownBlock {
            for url in [sourceURL, outputURL] where FileManager.default.fileExists(atPath: url.path()) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await Self.writeFixture(to: sourceURL, toneSeconds: [0, 1])

        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: try await videoTrack.load(.formatDescriptions).first
        )
        reader.add(output)
        writer.add(input)

        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        reader.cancelReading()

        let pipe = AudioTrackMixer.Pipe(reader: reader, writer: writer, output: output, input: input)
        await pipe.copy(on: DispatchQueue(label: "com.rselbach.reel.test.reader-cancel"))
        XCTAssertEqual(reader.status, .cancelled)
        writer.cancelWriting()
    }

    func testPipeCompletesWithoutHangingWhenWriterFailsOnPeerTrack() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Abed-WriterFail-\(UUID().uuidString).mp4")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Abed-WriterFailOut-\(UUID().uuidString).mp4")
        addTeardownBlock {
            for url in [sourceURL, outputURL] where FileManager.default.fileExists(atPath: url.path()) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await Self.writeFixture(to: sourceURL, toneSeconds: [0, 1])

        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: try await videoTrack.load(.formatDescriptions).first
        )
        let item = AVMutableMetadataItem()
        item.identifier = CursorMetadataTrack.identifier
        item.dataType = kCMMetadataBaseDataType_JSON as String
        item.value = ["version": 1] as NSDictionary
        let firstGroup = AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(
                start: CMTime(value: 1, timescale: 1),
                duration: CMTime(value: 1, timescale: 1)
            )
        )
        let peerInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: try XCTUnwrap(firstGroup.copyFormatDescription())
        )
        let peerAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: peerInput)
        reader.add(videoOutput)
        writer.add(videoInput)
        writer.add(peerInput)

        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.rselbach.reel.test.writer-fail")
        queue.suspend()
        let videoPipe = AudioTrackMixer.Pipe(
            reader: reader,
            writer: writer,
            output: videoOutput,
            input: videoInput
        )
        let copyTask = Task {
            await videoPipe.copy(on: queue)
        }
        try await Task.sleep(for: .milliseconds(20))

        // Fail the writer on the peer metadata track with a backwards timestamp.
        let backwardsGroup = AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(value: 1, timescale: 1)
            )
        )
        try await Self.waitUntilReady(peerInput)
        XCTAssertTrue(peerAdaptor.append(firstGroup))
        try await Self.waitUntilReady(peerInput)
        _ = peerAdaptor.append(backwardsGroup)
        peerInput.markAsFinished()

        queue.resume()
        await copyTask.value
        XCTAssertEqual(writer.status, .failed)
        reader.cancelReading()
    }

    func testPipeCompletesWithoutHangingWhenWriterIsCancelledDuringCopy() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Britta-WriterCancel-\(UUID().uuidString).mp4")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Britta-WriterCancelOut-\(UUID().uuidString).mp4")
        addTeardownBlock {
            for url in [sourceURL, outputURL] where FileManager.default.fileExists(atPath: url.path()) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await Self.writeFixture(to: sourceURL, toneSeconds: [0, 1])

        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: try await videoTrack.load(.formatDescriptions).first
        )
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: try await audioTrack.load(.formatDescriptions).first
        )
        reader.add(videoOutput)
        reader.add(audioOutput)
        writer.add(videoInput)
        writer.add(audioInput)

        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.rselbach.reel.test.writer-cancel")
        queue.suspend()
        let videoPipe = AudioTrackMixer.Pipe(
            reader: reader,
            writer: writer,
            output: videoOutput,
            input: videoInput
        )
        let copyTask = Task {
            await videoPipe.copy(on: queue)
        }
        // Let requestMediaDataWhenReady register before cancelling the writer,
        // then resume the queue so the callback observes a non-writing writer
        // even when isReadyForMoreMediaData is false.
        try await Task.sleep(for: .milliseconds(20))
        writer.cancelWriting()
        queue.resume()

        await copyTask.value
        XCTAssertEqual(writer.status, .cancelled)
        reader.cancelReading()
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
