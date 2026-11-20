import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

enum GIFExporter {
    enum ExportError: LocalizedError {
        case destinationUnavailable
        case frameRenderFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .destinationUnavailable:
                return "Could not create the GIF file."
            case .frameRenderFailed:
                return "A GIF frame could not be rendered."
            case .writeFailed:
                return "The GIF could not be written."
            }
        }
    }

    static func outputSize(
        for sourceSize: CGSize,
        maxDimension: CGFloat = GIFExport.maxWidth
    ) -> CGSize {
        guard
            sourceSize.width.isFinite,
            sourceSize.height.isFinite,
            sourceSize.width > 0,
            sourceSize.height > 0,
            maxDimension.isFinite,
            maxDimension > 0
        else {
            return sourceSize
        }
        let scale = min(1, min(maxDimension / sourceSize.width, maxDimension / sourceSize.height))
        return CGSize(
            width: max(1, (sourceSize.width * scale).rounded()),
            height: max(1, (sourceSize.height * scale).rounded())
        )
    }

    static func export(
        sourceURL: URL,
        outputURL: URL,
        edit: TimelineEdit,
        maxDimension: CGFloat = GIFExport.maxWidth,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let work = Task.detached(priority: .userInitiated) {
            try await writeGIF(
                sourceURL: sourceURL,
                outputURL: outputURL,
                edit: edit,
                maxDimension: maxDimension,
                onProgress: onProgress
            )
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func writeGIF(
        sourceURL: URL,
        outputURL: URL,
        edit: TimelineEdit,
        maxDimension: CGFloat,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if edit.zoomScenes.isEmpty {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }

        let sampling = GIFExport.frames(edit: edit)
        let imageContext = CIContext(options: [.cacheIntermediates: false])

        // Built in memory: a file destination writes through a hidden file of
        // its own that a cancelled export would leave behind.
        let gifData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                gifData as CFMutableData,
                UTType.gif.identifier as CFString,
                sampling.times.count,
                nil
            )
        else {
            throw ExportError.destinationUnavailable
        }

        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary
        )

        let frameProperties =
            [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: sampling.delay]
            ] as CFDictionary

        for (index, seconds) in sampling.times.enumerated() {
            try Task.checkCancellation()
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let frame = try await generator.image(at: time)
            try Task.checkCancellation()

            let renderedFrame: CGImage
            if edit.zoomScenes.isEmpty {
                renderedFrame = frame.image
            } else {
                let sourceImage = CIImage(cgImage: frame.image)
                let targetSize = outputSize(for: sourceImage.extent.size, maxDimension: maxDimension)
                let rendered = ZoomImageRenderer.render(
                    sourceImage,
                    sourceTime: seconds,
                    scenes: edit.zoomScenes,
                    outputSize: targetSize
                )
                guard let image = imageContext.createCGImage(rendered, from: rendered.extent) else {
                    throw ExportError.frameRenderFailed
                }
                renderedFrame = image
            }
            CGImageDestinationAddImage(destination, renderedFrame, frameProperties)
            await onProgress(Double(index + 1) / Double(sampling.times.count))
        }

        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed
        }
        try gifData.write(to: outputURL)
    }
}
