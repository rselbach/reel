import AVFoundation
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel",
    category: "AudioTrackMixer"
)

/// Folds a recording's microphone and system audio tracks into one.
///
/// The two sources are recorded as separate tracks so neither one's timing
/// can disturb the other, but Slack, browsers, and most players play only
/// the first audio track of an MP4. Video and cursor metadata are copied
/// untouched; only the audio is decoded and encoded again.
enum AudioTrackMixer {
    enum MixError: LocalizedError {
        case cannotAddTrack(AVMediaType)
        case cannotRead(Error?)
        case cannotWrite(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotAddTrack(let mediaType):
                return "The \(mediaType.rawValue) track could not be copied."
            case .cannotRead(let error):
                return "The recording could not be read: \(error?.localizedDescription ?? "unknown error")"
            case .cannotWrite(let error):
                return "The mixed recording could not be written: \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }

    /// The mix is decoded at the system audio's own rate and layout.
    private static var mixSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private static var encodedSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
    }

    /// Rewrites the file at `url` with its audio tracks mixed into one. Does
    /// nothing when there is at most one audio track. The original is only
    /// replaced once the mixed file is complete.
    @discardableResult
    static func mixAudioTracks(at url: URL) async throws -> FileReplacementWarning? {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return nil }

        let mixedURL = ExportFileNaming.temporaryURL(for: url)
        defer {
            if FileManager.default.fileExists(atPath: mixedURL.path(percentEncoded: false)) {
                do {
                    try FileManager.default.removeItem(at: mixedURL)
                } catch {
                    // A hidden leftover beside the recording is not worth
                    // failing a finished take over.
                    logger.error(
                        "Could not remove \(mixedURL.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: mixedURL, fileType: .mp4)
        var pipes: [Pipe] = []

        for track in try await asset.load(.tracks) where track.mediaType != .audio {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(
                mediaType: track.mediaType,
                outputSettings: nil,
                sourceFormatHint: try await track.load(.formatDescriptions).first
            )
            input.transform = try await track.load(.preferredTransform)
            try connect(output, to: input, reader: reader, writer: writer, mediaType: track.mediaType)
            pipes.append(Pipe(reader: reader, writer: writer, output: output, input: input))
        }

        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: mixSettings)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: encodedSettings)
        try connect(mixOutput, to: audioInput, reader: reader, writer: writer, mediaType: .audio)
        pipes.append(Pipe(reader: reader, writer: writer, output: mixOutput, input: audioInput))

        guard reader.startReading() else { throw MixError.cannotRead(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw MixError.cannotWrite(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // Every track is copied at once: the writer interleaves them and
        // stops taking one until the others catch up.
        await withTaskGroup(of: Void.self) { group in
            for (index, pipe) in pipes.enumerated() {
                group.addTask {
                    await pipe.copy(on: DispatchQueue(label: "com.rselbach.reel.audio-mix.\(index)"))
                }
            }
        }

        guard reader.status != .failed else {
            writer.cancelWriting()
            throw MixError.cannotRead(reader.error)
        }
        guard writer.status == .writing else {
            reader.cancelReading()
            throw MixError.cannotWrite(writer.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw MixError.cannotWrite(writer.error) }

        return try FileReplacement.commit(tempURL: mixedURL, to: url)
    }

    private static func connect(
        _ output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        mediaType: AVMediaType
    ) throws {
        guard reader.canAdd(output), writer.canAdd(input) else {
            throw MixError.cannotAddTrack(mediaType)
        }
        reader.add(output)
        writer.add(input)
    }

    private final class PipeCompletion: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<Void, Never>

        init(continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        deinit {
            // AVAssetWriterInput releases its readiness callback without
            // invoking it if the writer fails or is cancelled mid-copy.
            finish(markInputFinished: nil)
        }

        var hasFinished: Bool {
            state.withLock { $0 }
        }

        func finish(markInputFinished: (() -> Void)?) {
            let shouldFinish = state.withLock { finished -> Bool in
                guard !finished else { return false }
                finished = true
                return true
            }
            guard shouldFinish else { return }
            markInputFinished?()
            continuation.resume()
        }
    }

    /// One track's samples flowing from the reader to the writer. Each pipe
    /// is only touched on its own queue.
    struct Pipe: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput

        func copy(on queue: DispatchQueue) async {
            guard reader.status == .reading, writer.status == .writing else {
                if writer.status == .writing {
                    input.markAsFinished()
                }
                return
            }

            await withCheckedContinuation { continuation in
                let completion = PipeCompletion(continuation: continuation)
                let finish: @Sendable () -> Void = {
                    completion.finish {
                        if writer.status == .writing {
                            input.markAsFinished()
                        }
                    }
                }

                input.requestMediaDataWhenReady(on: queue) {
                    guard !completion.hasFinished else { return }
                    if reader.status != .reading || writer.status != .writing {
                        finish()
                        return
                    }
                    while input.isReadyForMoreMediaData {
                        if reader.status != .reading || writer.status != .writing {
                            finish()
                            return
                        }
                        let appended = autoreleasepool { () -> Bool in
                            guard let sample = output.copyNextSampleBuffer() else {
                                return false
                            }
                            return input.append(sample)
                        }
                        if !appended {
                            finish()
                            return
                        }
                    }
                    if reader.status != .reading || writer.status != .writing {
                        finish()
                    }
                }
            }
        }
    }
}
