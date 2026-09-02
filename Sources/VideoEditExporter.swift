import AVFoundation
import Foundation

enum VideoExportQuality: Sendable {
    case source
    case p720
}

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
        quality: VideoExportQuality,
        edit: TimelineEdit
    ) async throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let plan = try await ZoomVideoComposition.exportPlan(asset: sourceAsset, edit: edit)
        let preset: String
        switch quality {
        case .source:
            preset =
                plan.videoComposition == nil
                ? AVAssetExportPresetPassthrough
                : AVAssetExportPresetHighestQuality
        case .p720:
            preset = AVAssetExportPreset1280x720
        }

        guard let session = AVAssetExportSession(asset: plan.asset, presetName: preset) else {
            throw ExportError.presetUnavailable(preset)
        }
        if let timeRange = plan.timeRange {
            session.timeRange = timeRange
        }
        session.videoComposition = plan.videoComposition
        try await session.export(to: outputURL, as: .mp4)
    }
}
