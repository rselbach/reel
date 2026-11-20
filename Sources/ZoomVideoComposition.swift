import AVFoundation
import CoreImage

struct ZoomRenderScene: Equatable, Sendable {
    let span: TimelineSpan
    let sourceSceneSpan: TimelineSpan
    let sourceTimeAtStart: Double
    let focalPoint: UnitPoint2D
    let settings: ZoomSceneSettings

    func sourceTime(at renderTime: Double) -> Double {
        sourceTimeAtStart + renderTime - span.start
    }
}

struct ZoomFrameState: Equatable, Sendable {
    let focalPoint: UnitPoint2D
    let scale: Double
}

enum ZoomTransition {
    static func state(
        at time: Double,
        sceneSpan: TimelineSpan,
        focalPoint: UnitPoint2D,
        settings: ZoomSceneSettings
    ) -> ZoomFrameState? {
        guard
            time.isFinite,
            sceneSpan.start.isFinite,
            sceneSpan.end.isFinite,
            time >= sceneSpan.start,
            time < sceneSpan.end,
            sceneSpan.duration > 0
        else { return nil }

        let rampDuration = min(settings.transitionSpeed.duration, sceneSpan.duration / 2)
        let entering = min(1, (time - sceneSpan.start) / rampDuration)
        let exiting = min(1, (sceneSpan.end - time) / rampDuration)
        let progress = max(0, min(entering, exiting))
        let easedProgress = progress * progress * (3 - 2 * progress)
        return ZoomFrameState(
            focalPoint: focalPoint,
            scale: 1 + (settings.level.scale - 1) * easedProgress
        )
    }
}

enum ZoomImageRenderer {
    static func render(
        _ image: CIImage,
        sourceTime: Double,
        scenes: [ZoomScene],
        outputSize: CGSize? = nil
    ) -> CIImage {
        guard
            let scene = scenes.first(where: {
                sourceTime >= $0.span.start && sourceTime < $0.span.end
            })
        else {
            return render(image, state: nil, outputSize: outputSize)
        }
        let state = ZoomTransition.state(
            at: sourceTime,
            sceneSpan: scene.span,
            focalPoint: scene.focalPoint,
            settings: scene.settings
        )
        return render(image, state: state, outputSize: outputSize)
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
            focalPoint: scene.focalPoint,
            settings: scene.settings
        )
        return render(image, state: state)
    }

    static func render(
        _ image: CIImage,
        state: ZoomFrameState?,
        outputSize: CGSize? = nil
    ) -> CIImage {
        let sourceExtent = image.extent
        let targetSize = outputSize ?? sourceExtent.size
        let outputExtent = CGRect(origin: .zero, size: targetSize)
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -sourceExtent.minX,
                y: -sourceExtent.minY
            )
        )
        guard
            let state,
            let layout = ZoomLayout.resolve(
                sourceSize: sourceExtent.size,
                focalPoint: state.focalPoint,
                scale: state.scale
            ),
            let transform = layout.sourceToOutputTransform(outputSize: targetSize)
        else {
            guard sourceExtent.width > 0, sourceExtent.height > 0 else {
                return normalized.cropped(to: outputExtent)
            }
            let scaleX = targetSize.width / sourceExtent.width
            let scaleY = targetSize.height / sourceExtent.height
            if abs(scaleX - 1) < 1e-6 && abs(scaleY - 1) < 1e-6 {
                return normalized.cropped(to: outputExtent)
            }
            return
                normalized
                .clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .cropped(to: outputExtent)
        }

        return
            normalized
            .clampedToExtent()
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
        let keptRanges = edit.keptRanges
        let insertedRanges = insertedTimeRanges(for: keptRanges)
        let schedule = compactedSchedule(edit: edit, insertedRanges: insertedRanges)
        guard !schedule.isEmpty else {
            return try await planWithoutZoom(asset: asset, keptRanges: keptRanges)
        }

        let composition = AVMutableComposition()
        for entry in insertedRanges {
            try Task.checkCancellation()
            try await composition.insertTimeRange(
                entry.sourceTimeRange,
                of: asset,
                at: entry.outputStart,
                isolation: nil
            )
        }

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
        compactedSchedule(edit: edit, insertedRanges: insertedTimeRanges(for: edit.keptRanges))
    }

    private struct InsertedRange {
        let sourceTimeRange: CMTimeRange
        let outputStart: CMTime
    }

    private static func insertedTimeRanges(for keptRanges: [TimelineSpan]) -> [InsertedRange] {
        var result: [InsertedRange] = []
        var cursor = CMTime.zero
        for range in keptRanges {
            let timeRange = cmTimeRange(for: range)
            result.append(
                InsertedRange(
                    sourceTimeRange: timeRange,
                    outputStart: cursor
                )
            )
            cursor = CMTimeAdd(cursor, timeRange.duration)
        }
        return result
    }

    private static func compactedSchedule(
        edit: TimelineEdit,
        insertedRanges: [InsertedRange]
    ) -> [ZoomRenderScene] {
        var schedule: [ZoomRenderScene] = []
        for entry in insertedRanges {
            let outputStart = CMTimeGetSeconds(entry.outputStart)
            let sourceStart = CMTimeGetSeconds(entry.sourceTimeRange.start)
            let sourceEnd = CMTimeGetSeconds(entry.sourceTimeRange.end)
            for scene in edit.zoomScenes {
                let start = max(sourceStart, scene.span.start)
                let end = min(sourceEnd, scene.span.end)
                guard start < end else { continue }
                schedule.append(
                    ZoomRenderScene(
                        span: TimelineSpan(
                            start: outputStart + start - sourceStart,
                            end: outputStart + end - sourceStart
                        ),
                        sourceSceneSpan: scene.span,
                        sourceTimeAtStart: start,
                        focalPoint: scene.focalPoint,
                        settings: scene.settings
                    )
                )
            }
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
