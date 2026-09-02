import AVFoundation
import CoreImage

struct ZoomRenderScene: Equatable, Sendable {
    let span: TimelineSpan
    let focalPoint: UnitPoint2D
}

enum ZoomImageRenderer {
    static func render(
        _ image: CIImage,
        sourceTime: Double,
        scenes: [ZoomScene]
    ) -> CIImage {
        let focalPoint = scenes.first {
            sourceTime >= $0.span.start && sourceTime < $0.span.end
        }?.focalPoint
        return render(image, focalPoint: focalPoint)
    }

    static func render(
        _ image: CIImage,
        time: Double,
        schedule: [ZoomRenderScene]
    ) -> CIImage {
        let focalPoint = schedule.first {
            time >= $0.span.start && time < $0.span.end
        }?.focalPoint
        return render(image, focalPoint: focalPoint)
    }

    static func render(_ image: CIImage, focalPoint: UnitPoint2D?) -> CIImage {
        let sourceExtent = image.extent
        let outputExtent = CGRect(origin: .zero, size: sourceExtent.size)
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -sourceExtent.minX,
                y: -sourceExtent.minY
            )
        )
        guard
            let focalPoint,
            let layout = ZoomLayout.resolve(
                sourceSize: outputExtent.size,
                focalPoint: focalPoint
            ),
            let transform = layout.sourceToOutputTransform(outputSize: outputExtent.size)
        else {
            return normalized.cropped(to: outputExtent)
        }

        return
            normalized
            .cropped(to: layout.sourceCropRect)
            .transformed(by: transform)
            .cropped(to: outputExtent)
    }
}

struct ZoomExportPlan {
    let asset: AVAsset
    let timeRange: CMTimeRange?
    let videoComposition: AVVideoComposition?
}

enum ZoomVideoComposition {
    static func preview(asset: AVAsset, scenes: [ZoomScene]) async throws -> AVVideoComposition? {
        guard !scenes.isEmpty else { return nil }
        return try await AVVideoComposition(applyingFiltersTo: asset) { request in
            let seconds = CMTimeGetSeconds(request.compositionTime)
            let output = ZoomImageRenderer.render(
                request.sourceImage,
                sourceTime: seconds,
                scenes: scenes
            )
            return AVCIImageFilteringResult(resultImage: output)
        }
    }

    static func exportPlan(asset: AVAsset, edit: TimelineEdit) async throws -> ZoomExportPlan {
        guard !edit.zoomScenes.isEmpty else {
            return try await planWithoutZoom(asset: asset, keptRanges: edit.keptRanges)
        }

        let composition = AVMutableComposition()
        var outputCursor = 0.0
        for range in edit.keptRanges {
            try Task.checkCancellation()
            let timeRange = cmTimeRange(for: range)
            try await composition.insertTimeRange(
                timeRange,
                of: asset,
                at: CMTime(seconds: outputCursor, preferredTimescale: 600),
                isolation: nil
            )
            outputCursor += range.duration
        }

        let schedule = compactedSchedule(edit: edit)
        let videoComposition = try await AVVideoComposition(applyingFiltersTo: composition) { request in
            let seconds = CMTimeGetSeconds(request.compositionTime)
            let output = ZoomImageRenderer.render(
                request.sourceImage,
                time: seconds,
                schedule: schedule
            )
            return AVCIImageFilteringResult(resultImage: output)
        }
        return ZoomExportPlan(
            asset: composition,
            timeRange: nil,
            videoComposition: videoComposition
        )
    }

    static func compactedSchedule(edit: TimelineEdit) -> [ZoomRenderScene] {
        var schedule: [ZoomRenderScene] = []
        var outputCursor = 0.0

        for keptRange in edit.keptRanges {
            for scene in edit.zoomScenes {
                let start = max(keptRange.start, scene.span.start)
                let end = min(keptRange.end, scene.span.end)
                guard start < end else { continue }
                schedule.append(
                    ZoomRenderScene(
                        span: TimelineSpan(
                            start: outputCursor + start - keptRange.start,
                            end: outputCursor + end - keptRange.start
                        ),
                        focalPoint: scene.focalPoint
                    )
                )
            }
            outputCursor += keptRange.duration
        }
        return schedule
    }

    private static func planWithoutZoom(
        asset: AVAsset,
        keptRanges: [TimelineSpan]
    ) async throws -> ZoomExportPlan {
        if keptRanges.count == 1, let range = keptRanges.first {
            return ZoomExportPlan(
                asset: asset,
                timeRange: cmTimeRange(for: range),
                videoComposition: nil
            )
        }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for range in keptRanges {
            try Task.checkCancellation()
            let timeRange = cmTimeRange(for: range)
            try await composition.insertTimeRange(timeRange, of: asset, at: cursor, isolation: nil)
            cursor = CMTimeAdd(cursor, timeRange.duration)
        }
        return ZoomExportPlan(asset: composition, timeRange: nil, videoComposition: nil)
    }

    private static func cmTimeRange(for span: TimelineSpan) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: span.start, preferredTimescale: 600),
            end: CMTime(seconds: span.end, preferredTimescale: 600)
        )
    }
}
