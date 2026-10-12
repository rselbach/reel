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

    /// Writes the edited recording to `outputURL`, reporting progress from 0
    /// to 1 along the way and 1 once the file is complete. Cancelling the
    /// calling task stops the export and throws CancellationError.
    static func export(
        sourceURL: URL,
        outputURL: URL,
        quality: VideoExportQuality,
        edit: TimelineEdit,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
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

        let states = session.states(updateInterval: 0.1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in states {
                    if case .exporting(let progress) = state {
                        await onProgress(progress.fractionCompleted)
                    }
                }
            }
            try await session.export(to: outputURL, as: .mp4)
            group.cancelAll()
        }
        await onProgress(1)
    }
}
