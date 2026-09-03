import AVFoundation
import CoreImage

struct ZoomRenderScene: Equatable, Sendable {
    let span: TimelineSpan
    let sourceSceneSpan: TimelineSpan
    let sourceTimeAtStart: Double
    let focalPoint: UnitPoint2D

    func sourceTime(at renderTime: Double) -> Double {
        sourceTimeAtStart + renderTime - span.start
    }
}

struct ZoomFrameState: Equatable, Sendable {
    let focalPoint: UnitPoint2D
    let scale: Double
}

enum ZoomTransition {
    static let duration = 0.25

    static func state(
        at time: Double,
        sceneSpan: TimelineSpan,
        focalPoint: UnitPoint2D
    ) -> ZoomFrameState? {
        guard
            time.isFinite,
            sceneSpan.start.isFinite,
            sceneSpan.end.isFinite,
            time >= sceneSpan.start,
            time < sceneSpan.end,
            sceneSpan.duration > 0
        else { return nil }

        let rampDuration = min(duration, sceneSpan.duration / 2)
        let entering = min(1, (time - sceneSpan.start) / rampDuration)
        let exiting = min(1, (sceneSpan.end - time) / rampDuration)
        let progress = max(0, min(entering, exiting))
        let easedProgress = progress * progress * (3 - 2 * progress)
        return ZoomFrameState(
            focalPoint: focalPoint,
            scale: 1 + (ZoomScene.scale - 1) * easedProgress
        )
    }
}

enum ZoomImageRenderer {
    static func render(
        _ image: CIImage,
        sourceTime: Double,
        scenes: [ZoomScene]
    ) -> CIImage {
        guard
            let scene = scenes.first(where: {
                sourceTime >= $0.span.start && sourceTime < $0.span.end
            })
        else {
            return render(image, state: nil)
        }
        let state = ZoomTransition.state(
            at: sourceTime,
            sceneSpan: scene.span,
            focalPoint: scene.focalPoint
        )
        return render(image, state: state)
    }

    static func render(
        _ image: CIImage,
        time: Double,
        schedule: [ZoomRenderScene]
    ) -> CIImage {
        guard
            let scene = schedule.first(where: {
                time >= $0.span.start && time < $0.span.end
            })
        else {
            return render(image, state: nil)
        }
        let sourceTime = scene.sourceTime(at: time)
        let state = ZoomTransition.state(
            at: sourceTime,
            sceneSpan: scene.sourceSceneSpan,
            focalPoint: scene.focalPoint
        )
        return render(image, state: state)
    }

    static func render(_ image: CIImage, state: ZoomFrameState?) -> CIImage {
        let sourceExtent = image.extent
        let outputExtent = CGRect(origin: .zero, size: sourceExtent.size)
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -sourceExtent.minX,
                y: -sourceExtent.minY
            )
        )
        guard
            let state,
            let layout = ZoomLayout.resolve(
                sourceSize: outputExtent.size,
                focalPoint: state.focalPoint,
                scale: state.scale
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
                        sourceSceneSpan: scene.span,
                        sourceTimeAtStart: start,
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
