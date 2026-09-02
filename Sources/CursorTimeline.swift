@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Cursor positions recorded on the video's timeline. Positions use normalized
/// final-frame coordinates with a bottom-left origin; nil means the cursor was
/// outside the recorded area.
struct CursorTimeline: Equatable, Sendable {
    struct Position: Decodable, Equatable, Sendable {
        let x: Double
        let y: Double

        init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        init(_ point: CGPoint) {
            self.init(x: point.x, y: point.y)
        }
    }

    struct Sample: Equatable, Sendable {
        let time: Double
        let position: Position?
        let pressedButtons: UInt64
    }

    let samples: [Sample]

    static let empty = CursorTimeline(samples: [])

    /// Returns the most recent cursor state at or before a source-video time.
    /// Consumers can hold this state until the next sample arrives.
    func sample(at time: Double) -> Sample? {
        guard time.isFinite, !samples.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = samples.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if samples[middle].time <= time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        guard lowerBound > 0 else { return nil }
        return samples[lowerBound - 1]
    }
}

enum CursorTimelineLayout {
    /// Converts a position over captured content into a position over the
    /// encoded frame, accounting for the padding around framed windows.
    static func outputPosition(
        contentPosition: CGPoint?,
        contentSize: CGSize,
        windowFrame: FrameCompositor.WindowFrame?
    ) -> CursorTimeline.Position? {
        guard let contentPosition else { return nil }
        guard contentPosition.x.isFinite, contentPosition.y.isFinite else { return nil }

        guard let windowFrame else {
            return CursorTimeline.Position(contentPosition)
        }
        guard
            contentSize.width > 0,
            contentSize.height > 0,
            windowFrame.canvasSize.width > 0,
            windowFrame.canvasSize.height > 0
        else { return nil }

        return CursorTimeline.Position(
            x: (windowFrame.contentOrigin.x + contentPosition.x * contentSize.width)
                / windowFrame.canvasSize.width,
            y: (windowFrame.contentOrigin.y + contentPosition.y * contentSize.height)
                / windowFrame.canvasSize.height
        )
    }
}

enum CursorMetadataTrack {
    static let identifier = AVMetadataIdentifier("mdta/com.rselbach.reel.cursor.v1")

    struct CapturedState: Equatable, Sendable {
        let contentPosition: CGPoint?
        let pressedButtons: UInt64

        static let outside = CapturedState(contentPosition: nil, pressedButtons: 0)
    }

    private struct Payload: Decodable {
        let version: Int
        let position: CursorTimeline.Position?
        let pressedButtons: UInt64
    }

    final class Writer {
        let input: AVAssetWriterInput

        private let adaptor: AVAssetWriterInputMetadataAdaptor
        private let sampleDuration: CMTime

        init(assetWriter: AVAssetWriter, frameRate: Int) throws {
            sampleDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
            let prototype = CursorMetadataTrack.group(
                position: nil,
                pressedButtons: 0,
                time: .zero,
                duration: sampleDuration
            )
            guard let formatDescription = prototype.copyFormatDescription() else {
                throw CursorMetadataError.cannotCreateFormatDescription
            }

            let input = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: formatDescription
            )
            input.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(input) else {
                throw CursorMetadataError.cannotAddTrack
            }
            assetWriter.add(input)

            self.input = input
            adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        }

        /// A temporarily back-pressured metadata input may drop one sample;
        /// readers hold the preceding state until the next one arrives.
        func append(
            position: CursorTimeline.Position?,
            pressedButtons: UInt64,
            at time: CMTime
        ) -> Bool {
            guard input.isReadyForMoreMediaData else { return true }
            let group = CursorMetadataTrack.group(
                position: position,
                pressedButtons: pressedButtons,
                time: time,
                duration: sampleDuration
            )
            return adaptor.append(group)
        }
    }

    static func load(from url: URL) async throws -> CursorTimeline {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        var samples: [CursorTimeline.Sample] = []

        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)

            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else {
                throw CursorMetadataError.cannotStartReading(reader.error)
            }

            while let group = adaptor.nextTimedMetadataGroup() {
                guard
                    let item = group.items.first(where: { $0.identifier == identifier }),
                    let value = try await item.load(.value),
                    JSONSerialization.isValidJSONObject(value)
                else { continue }

                let data = try JSONSerialization.data(withJSONObject: value)
                let payload = try JSONDecoder().decode(Payload.self, from: data as Data)
                guard payload.version == 1 else { continue }

                let seconds = CMTimeGetSeconds(group.timeRange.start)
                guard seconds.isFinite else { continue }
                samples.append(
                    CursorTimeline.Sample(
                        time: seconds,
                        position: payload.position,
                        pressedButtons: payload.pressedButtons
                    )
                )
            }

            if reader.status == .failed {
                throw CursorMetadataError.readFailed(reader.error)
            }
        }

        samples.sort { $0.time < $1.time }
        return CursorTimeline(samples: samples)
    }

    private static func group(
        position: CursorTimeline.Position?,
        pressedButtons: UInt64,
        time: CMTime,
        duration: CMTime
    ) -> AVTimedMetadataGroup {
        let encodedPosition: Any =
            position.map {
                ["x": $0.x, "y": $0.y] as NSDictionary
            } ?? NSNull()
        let payload =
            [
                "version": NSNumber(value: 1),
                "position": encodedPosition,
                "pressedButtons": NSNumber(value: pressedButtons),
            ] as NSDictionary
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.dataType = kCMMetadataBaseDataType_JSON as String
        item.value = payload
        return AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(start: time, duration: duration)
        )
    }
}

enum CursorMetadataError: LocalizedError {
    case cannotCreateFormatDescription
    case cannotAddTrack
    case cannotStartReading(Error?)
    case readFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .cannotCreateFormatDescription:
            return "Could not describe the cursor metadata track."
        case .cannotAddTrack:
            return "Could not add the cursor metadata track to the recording."
        case .cannotStartReading(let error):
            return error?.localizedDescription ?? "Could not read the cursor metadata track."
        case .readFailed(let error):
            return error?.localizedDescription ?? "Reading the cursor metadata track failed."
        }
    }
}
