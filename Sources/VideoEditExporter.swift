import AVFoundation
import Foundation

enum VideoEditExporter {
    enum ExportError: LocalizedError {
        case presetUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .presetUnavailable(let preset):
                return "This recording cannot be exported with the \(preset) preset."
            }
        }
    }

    static func export(
        sourceURL: URL,
        outputURL: URL,
        preset: String,
        edit: TimelineEdit
    ) async throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let exportAsset: AVAsset
        let directTimeRange: CMTimeRange?

        if edit.keptRanges.count == 1, let range = edit.keptRanges.first {
            exportAsset = sourceAsset
            directTimeRange = cmTimeRange(for: range)
        } else {
            let composition = AVMutableComposition()
            var cursor = CMTime.zero
            for range in edit.keptRanges {
                try Task.checkCancellation()
                let timeRange = cmTimeRange(for: range)
                try await composition.insertTimeRange(timeRange, of: sourceAsset, at: cursor, isolation: nil)
                cursor = CMTimeAdd(cursor, timeRange.duration)
            }
            exportAsset = composition
            directTimeRange = nil
        }

        guard let session = AVAssetExportSession(asset: exportAsset, presetName: preset) else {
            throw ExportError.presetUnavailable(preset)
        }
        if let directTimeRange {
            session.timeRange = directTimeRange
        }
        try await session.export(to: outputURL, as: .mp4)
    }

    private static func cmTimeRange(for span: TimelineSpan) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: span.start, preferredTimescale: 600),
            end: CMTime(seconds: span.end, preferredTimescale: 600)
        )
    }
}
