import AVFoundation
import CoreGraphics
import SwiftUI
import os

private let timelineLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel",
    category: "PostRecordingTimelineView"
)

enum TimelineSelection: Equatable, Sendable {
    case none
    case clip(TimelineClip.ID)
    case zoomScene(ZoomScene.ID)

    func validated(for edit: TimelineEdit) -> TimelineSelection {
        switch self {
        case .none:
            return .none
        case .clip(let id):
            return edit.clip(id: id) == nil ? .none : .clip(id)
        case .zoomScene(let id):
            return edit.zoomScene(id: id) == nil ? .none : .zoomScene(id)
        }
    }
}

enum PostRecordingTimelineMath {
    static let preferredThumbnailWidth: CGFloat = 96
    static let minimumThumbnailCount = 3
    static let maximumThumbnailCount = 24

    static func position(for time: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard time.isFinite, duration.isFinite, duration > 0, width.isFinite, width > 0 else {
            return 0
        }
        let progress = min(max(0, time / duration), 1)
        return width * progress
    }

    static func sourceTime(at position: CGFloat, duration: Double, width: CGFloat) -> Double {
        guard position.isFinite, duration.isFinite, duration > 0, width.isFinite, width > 0 else {
            return 0
        }
        let progress = min(max(0, position / width), 1)
        return duration * progress
    }

    static func translatedSourceTime(
        origin: Double,
        translation: CGFloat,
        duration: Double,
        width: CGFloat
    ) -> Double {
        guard origin.isFinite else { return 0 }
        return sourceTime(
            at: position(for: origin, duration: duration, width: width) + translation,
            duration: duration,
            width: width
        )
    }

    static func width(for span: TimelineSpan, duration: Double, width: CGFloat) -> CGFloat {
        let start = position(for: span.start, duration: duration, width: width)
        let end = position(for: span.end, duration: duration, width: width)
        return max(0, end - start)
    }

    static func thumbnailCount(forWidth width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return minimumThumbnailCount }
        let count = Int(ceil(width / preferredThumbnailWidth))
        return min(maximumThumbnailCount, max(minimumThumbnailCount, count))
    }

    static func thumbnailSampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        return (0..<count).map { index in
            duration * (Double(index) + 0.5) / Double(count)
        }
    }

    static func editedTime(forSourceTime sourceTime: Double, edit: TimelineEdit) -> Double {
        guard sourceTime.isFinite else { return 0 }
        let clamped = min(max(sourceTime, 0), edit.sourceDuration)
        var editedTime = 0.0

        for range in edit.keptRanges {
            if clamped < range.start {
                return editedTime
            }
            if clamped <= range.end {
                return editedTime + clamped - range.start
            }
            editedTime += range.duration
        }
        return edit.editedDuration
    }

    static func sourceTimeBySkipping(
        fromSourceTime sourceTime: Double,
        seconds: Double,
        edit: TimelineEdit
    ) -> Double? {
        guard seconds.isFinite else { return nil }
        let currentEditedTime = editedTime(forSourceTime: sourceTime, edit: edit)
        let targetEditedTime = min(max(0, currentEditedTime + seconds), edit.editedDuration)
        return edit.sourceTime(forEditedTime: targetEditedTime)
    }

    static func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        let minutes = tenths / 600
        let wholeSeconds = (tenths / 10) % 60
        return String(format: "%d:%02d.%d", minutes, wholeSeconds, tenths % 10)
    }
}

private enum ZoomResizeEdge: Equatable {
    case leading
    case trailing
}

private struct ZoomResizeState {
    let sceneID: ZoomScene.ID
    let edge: ZoomResizeEdge
    let originalSpan: TimelineSpan
    var currentSpan: TimelineSpan
}

struct PostRecordingTimelineView: View {
    let videoURL: URL
    @Binding var edit: TimelineEdit
    let currentSourceTime: Double
    @Binding var selection: TimelineSelection
    let onSeek: (Double) -> Void
    let onSelectZoomScene: (ZoomScene.ID) -> Void

    @State private var playheadDragOrigin: Double?
    @State private var zoomDraftStart: Double?
    @State private var zoomDraftSpan: TimelineSpan?
    @State private var zoomResizeState: ZoomResizeState?
    @State private var showsEditError = false
    @State private var editErrorMessage = ""
    @AccessibilityFocusState private var focusedClipID: TimelineClip.ID?
    @AccessibilityFocusState private var focusedZoomSceneID: ZoomScene.ID?

    private let timelineGutter: CGFloat = 8
    private let zoomLaneHeight: CGFloat = 30
    private let laneSpacing: CGFloat = 6
    private let filmstripHeight: CGFloat = 104

    private var timelineContentHeight: CGFloat {
        zoomLaneHeight + laneSpacing + filmstripHeight
    }

    var body: some View {
        VStack(spacing: 10) {
            selectionControls

            GeometryReader { geometry in
                let timelineWidth = max(1, geometry.size.width - timelineGutter * 2)

                ZStack(alignment: .topLeading) {
                    zoomLane(width: timelineWidth)
                        .offset(x: timelineGutter)

                    ThumbnailFilmstrip(
                        videoURL: videoURL,
                        duration: edit.sourceDuration,
                        count: PostRecordingTimelineMath.thumbnailCount(forWidth: timelineWidth)
                    )
                    .frame(width: timelineWidth, height: filmstripHeight)
                    .offset(x: timelineGutter, y: zoomLaneHeight + laneSpacing)
                    .accessibilityHidden(true)

                    ForEach(edit.clips) { clip in
                        clipSegment(
                            clip,
                            timelineWidth: timelineWidth,
                            gutter: timelineGutter
                        )
                        .offset(y: zoomLaneHeight + laneSpacing)
                    }

                    timelineGestureTarget(width: timelineWidth)
                        .offset(x: timelineGutter, y: zoomLaneHeight + laneSpacing)

                    playhead(timelineWidth: timelineWidth, gutter: timelineGutter)
                }
                .contextMenu {
                    timelineContextMenu
                }
            }
            .frame(height: timelineContentHeight + 14)

            HStack {
                Text(PostRecordingTimelineMath.formattedTime(0))
                Spacer()
                Text("Source \(PostRecordingTimelineMath.formattedTime(currentSourceTime))")
                Spacer()
                Text(PostRecordingTimelineMath.formattedTime(edit.sourceDuration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .alert(PostRecordingText.editClipFailedTitle, isPresented: $showsEditError) {
            Button("OK") {}
        } message: {
            Text(editErrorMessage)
        }
        .onDeleteCommand {
            deleteSelection()
        }
    }

    private var selectionControls: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PostRecordingText.timeline)
                    .font(.headline)
                Text(selectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if case .clip(let id) = selection, let clip = edit.clip(id: id) {
                Button(PostRecordingText.clearSelection) {
                    selection = .none
                }
                .keyboardShortcut(.cancelAction)

                if clip.isDeleted {
                    Button(PostRecordingText.restoreClip) {
                        restoreClip(id: id)
                    }
                } else {
                    Button(PostRecordingText.deleteClip, role: .destructive) {
                        deleteClip(id: id)
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!edit.canDeleteClip(id: id))
                }
            } else if case .zoomScene(let id) = selection, edit.zoomScene(id: id) != nil {
                Button(PostRecordingText.clearSelection) {
                    selection = .none
                }
                .keyboardShortcut(.cancelAction)

                Button(PostRecordingText.deleteZoomScene, role: .destructive) {
                    removeZoomScene(id: id)
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
    }

    private var selectionDescription: String {
        if case .zoomScene(let id) = selection, let scene = edit.zoomScene(id: id) {
            return "Selected 150% zoom scene, source \(formattedRange(scene.span))."
        }
        guard case .clip(let id) = selection, let clip = edit.clip(id: id) else {
            return PostRecordingText.timelineHelp
        }
        let prefix = clip.isDeleted ? "Deleted clip" : "Selected clip"
        return "\(prefix) source \(formattedRange(clip.span))."
    }

    @ViewBuilder
    private var timelineContextMenu: some View {
        if let id = contextClipID, let clip = edit.clip(id: id) {
            if clip.isDeleted {
                Button(PostRecordingText.restoreClip) {
                    restoreClip(id: id)
                }
            } else {
                Button(PostRecordingText.deleteClip, role: .destructive) {
                    deleteClip(id: id)
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!edit.canDeleteClip(id: id))
            }

            Divider()
        }

        Button(PostRecordingText.splitClipAtPlayhead) {
            splitClipAtPlayhead()
        }
        .keyboardShortcut("b", modifiers: .command)
        .disabled(!edit.canSplit(at: currentSourceTime))
    }

    private var contextClipID: TimelineClip.ID? {
        if case .clip(let id) = selection, edit.clip(id: id)?.isDeleted == true {
            return id
        }
        return edit.clipID(at: currentSourceTime)
    }

    private func timelineGestureTarget(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: width, height: filmstripHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.width) >= 3 else { return }
                        seekAndSelect(at: value.location.x, width: width)
                    }
                    .onEnded { value in
                        seekAndSelect(at: value.location.x, width: width)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(PostRecordingText.sourceTimeline)
            .accessibilityValue(selectionDescription)
            .accessibilityHint(PostRecordingText.timelineHelp)
            .accessibilityAction(named: Text(PostRecordingText.splitClipAtPlayhead)) {
                splitClipAtPlayhead()
            }
    }

    private func zoomLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(zoomLaneGesture(width: width))

            if let zoomDraftSpan {
                zoomBlock(span: zoomDraftSpan, width: width, isSelected: false)
                    .offset(x: position(zoomDraftSpan.start, in: width))
                    .opacity(0.65)
                    .allowsHitTesting(false)
            }

            ForEach(edit.zoomScenes) { scene in
                zoomSceneBlock(scene, width: width)
            }

            if edit.zoomScenes.isEmpty, zoomDraftSpan == nil {
                Text(PostRecordingText.zoomLaneEmpty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: zoomLaneHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PostRecordingText.zoomLane)
        .accessibilityValue("\(edit.zoomScenes.count) zoom scenes")
        .accessibilityHint(PostRecordingText.zoomLaneHint)
        .accessibilityAction(named: Text(PostRecordingText.addZoomSceneAtPlayhead)) {
            addZoomSceneAtPlayhead()
        }
    }

    private func zoomSceneBlock(_ scene: ZoomScene, width: CGFloat) -> some View {
        let isSelected = selection == .zoomScene(scene.id)
        let span = displayedZoomSpan(for: scene)
        let blockWidth = PostRecordingTimelineMath.width(
            for: span,
            duration: edit.sourceDuration,
            width: width
        )

        return zoomBlock(span: span, width: width, isSelected: isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
                selection = .zoomScene(scene.id)
                focusedZoomSceneID = scene.id
                onSelectZoomScene(scene.id)
            }
            .overlay(alignment: .trailing) {
                if isSelected, blockWidth >= 88 {
                    Button {
                        removeZoomScene(id: scene.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.trailing, 12)
                    .accessibilityLabel(PostRecordingText.deleteZoomScene)
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    zoomResizeHandle(
                        scene: scene,
                        span: span,
                        edge: .leading,
                        width: width
                    )
                    .offset(x: -8)
                }
            }
            .overlay(alignment: .trailing) {
                if isSelected {
                    zoomResizeHandle(
                        scene: scene,
                        span: span,
                        edge: .trailing,
                        width: width
                    )
                    .offset(x: 8)
                }
            }
            .contextMenu {
                Button(PostRecordingText.deleteZoomScene, role: .destructive) {
                    removeZoomScene(id: scene.id)
                }
            }
            .offset(x: position(span.start, in: width))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(PostRecordingText.zoomScene)
            .accessibilityValue("150 percent, source \(formattedRange(span))")
            .accessibilityHint("Select to set the focal point. Drag either edge to resize.")
            .accessibilityFocused($focusedZoomSceneID, equals: scene.id)
            .accessibilityAction {
                selection = .zoomScene(scene.id)
                onSelectZoomScene(scene.id)
            }
            .accessibilityAction(named: Text(PostRecordingText.deleteZoomScene)) {
                removeZoomScene(id: scene.id)
            }
    }

    private func displayedZoomSpan(for scene: ZoomScene) -> TimelineSpan {
        guard zoomResizeState?.sceneID == scene.id else { return scene.span }
        return zoomResizeState?.currentSpan ?? scene.span
    }

    private func zoomResizeHandle(
        scene: ZoomScene,
        span: TimelineSpan,
        edge: ZoomResizeEdge,
        width: CGFloat
    ) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(.white)
                .frame(width: 4, height: 18)
                .shadow(color: .black.opacity(0.45), radius: 1)
        }
        .frame(width: 16, height: zoomLaneHeight)
        .contentShape(Rectangle())
        .gesture(zoomResizeGesture(scene: scene, edge: edge, width: width))
        .accessibilityElement()
        .accessibilityLabel(edge == .leading ? "Zoom start" : "Zoom end")
        .accessibilityValue(
            PostRecordingTimelineMath.formattedTime(
                edge == .leading ? span.start : span.end
            )
        )
        .accessibilityHint("Drag horizontally to resize the zoom scene.")
        .accessibilityAdjustableAction { direction in
            adjustZoomEdge(scene: scene, edge: edge, direction: direction)
        }
    }

    private func zoomResizeGesture(
        scene: ZoomScene,
        edge: ZoomResizeEdge,
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let state: ZoomResizeState
                if let current = zoomResizeState,
                    current.sceneID == scene.id,
                    current.edge == edge
                {
                    state = current
                } else {
                    state = ZoomResizeState(
                        sceneID: scene.id,
                        edge: edge,
                        originalSpan: scene.span,
                        currentSpan: scene.span
                    )
                }
                let seconds = Double(value.translation.width / width) * edit.sourceDuration
                guard
                    let span = resizedZoomSpan(
                        sceneID: scene.id,
                        span: state.originalSpan,
                        edge: edge,
                        offset: seconds
                    )
                else { return }
                zoomResizeState = ZoomResizeState(
                    sceneID: state.sceneID,
                    edge: state.edge,
                    originalSpan: state.originalSpan,
                    currentSpan: span
                )
            }
            .onEnded { _ in
                finishZoomResize(sceneID: scene.id)
            }
    }

    private func adjustZoomEdge(
        scene: ZoomScene,
        edge: ZoomResizeEdge,
        direction: AccessibilityAdjustmentDirection
    ) {
        let offset = adjustment(for: direction, amount: 0.1)
        guard
            offset != 0,
            let span = resizedZoomSpan(
                sceneID: scene.id,
                span: scene.span,
                edge: edge,
                offset: offset
            )
        else { return }
        do {
            try edit.resizeZoomScene(id: scene.id, to: span)
        } catch {
            showEditError(error.localizedDescription)
        }
    }

    private func resizedZoomSpan(
        sceneID: ZoomScene.ID,
        span: TimelineSpan,
        edge: ZoomResizeEdge,
        offset: Double
    ) -> TimelineSpan? {
        guard let bounds = edit.zoomSceneResizeBounds(id: sceneID) else { return nil }
        switch edge {
        case .leading:
            return TimelineSpan(
                start: min(
                    max(bounds.start, span.start + offset),
                    span.end - TimelineEdit.minimumZoomSceneDuration
                ),
                end: span.end
            )
        case .trailing:
            return TimelineSpan(
                start: span.start,
                end: max(
                    min(bounds.end, span.end + offset),
                    span.start + TimelineEdit.minimumZoomSceneDuration
                )
            )
        }
    }

    private func finishZoomResize(sceneID: ZoomScene.ID) {
        guard let state = zoomResizeState, state.sceneID == sceneID else { return }
        zoomResizeState = nil
        guard state.currentSpan != state.originalSpan else { return }
        do {
            try edit.resizeZoomScene(id: sceneID, to: state.currentSpan)
        } catch {
            showEditError(error.localizedDescription)
        }
    }

    private func zoomBlock(span: TimelineSpan, width: CGFloat, isSelected: Bool) -> some View {
        let blockWidth = PostRecordingTimelineMath.width(
            for: span,
            duration: edit.sourceDuration,
            width: width
        )
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(isSelected ? 0.85 : 0.62))
            if blockWidth >= 60 {
                Text("Zoom 150%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            RoundedRectangle(cornerRadius: 5)
                .stroke(.white.opacity(isSelected ? 1 : 0.75), lineWidth: isSelected ? 2 : 1)
        }
        .frame(width: max(3, blockWidth), height: zoomLaneHeight)
    }

    private func zoomLaneGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = PostRecordingTimelineMath.sourceTime(
                    at: value.location.x,
                    duration: edit.sourceDuration,
                    width: width
                )
                if zoomDraftStart == nil {
                    guard edit.availableZoomSpan(containing: time) != nil else { return }
                    zoomDraftStart = time
                }
                guard
                    let start = zoomDraftStart,
                    let gap = edit.availableZoomSpan(containing: start)
                else { return }
                zoomDraftSpan = TimelineSpan(
                    start: max(gap.start, min(start, time)),
                    end: min(gap.end, max(start, time))
                )
            }
            .onEnded { value in
                defer {
                    zoomDraftStart = nil
                    zoomDraftSpan = nil
                }
                guard let span = zoomDraftSpan else { return }
                if span.duration < TimelineEdit.minimumZoomSceneDuration {
                    let time = PostRecordingTimelineMath.sourceTime(
                        at: value.location.x,
                        duration: edit.sourceDuration,
                        width: width
                    )
                    onSeek(time)
                    return
                }
                addZoomScene(span: span)
            }
    }

    private func addZoomScene(span: TimelineSpan) {
        do {
            let id = try edit.addZoomScene(span: span)
            selection = .zoomScene(id)
            focusedZoomSceneID = id
            onSelectZoomScene(id)
        } catch {
            showEditError(error.localizedDescription)
        }
    }

    private func addZoomSceneAtPlayhead() {
        guard let gap = edit.availableZoomSpan(containing: currentSourceTime) else {
            showEditError(ZoomSceneEditError.overlapsExistingScene.localizedDescription)
            return
        }
        let duration = min(1, gap.duration)
        guard duration >= TimelineEdit.minimumZoomSceneDuration else {
            showEditError(ZoomSceneEditError.invalidSpan.localizedDescription)
            return
        }
        let start = min(max(gap.start, currentSourceTime), gap.end - duration)
        addZoomScene(span: TimelineSpan(start: start, end: start + duration))
    }

    private func deleteSelection() {
        switch selection {
        case .clip(let id):
            guard edit.clip(id: id)?.isDeleted == false else { return }
            deleteClip(id: id)
        case .zoomScene(let id):
            removeZoomScene(id: id)
        case .none:
            return
        }
    }

    private func removeZoomScene(id: ZoomScene.ID) {
        if zoomResizeState?.sceneID == id {
            zoomResizeState = nil
        }
        edit.removeZoomScene(id: id)
        selection = .none
    }

    private func clipSegment(
        _ clip: TimelineClip,
        timelineWidth: CGFloat,
        gutter: CGFloat
    ) -> some View {
        let width = PostRecordingTimelineMath.width(
            for: clip.span,
            duration: edit.sourceDuration,
            width: timelineWidth
        )
        let isSelected = selection == .clip(clip.id)

        return ZStack {
            if clip.isDeleted {
                Rectangle()
                    .fill(Color.red.opacity(isSelected ? 0.72 : 0.58))
                TimelineClipHatch()
                    .stroke(.white.opacity(0.7), lineWidth: 2)
                if width >= 56 {
                    Text(PostRecordingText.deleted)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                }
            } else if isSelected {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.24))
            }

            Rectangle()
                .stroke(
                    isSelected ? Color.accentColor : Color.white.opacity(0.7),
                    lineWidth: isSelected ? 3 : 1
                )
        }
        .frame(width: max(2, width), height: filmstripHeight)
        .offset(x: gutter + position(clip.span.start, in: timelineWidth))
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(clip.isDeleted ? PostRecordingText.deletedClip : PostRecordingText.clip)
        .accessibilityValue("Source \(formattedRange(clip.span))")
        .accessibilityHint(PostRecordingText.clipHint)
        .accessibilityFocused($focusedClipID, equals: clip.id)
        .accessibilityAction {
            selectClip(id: clip.id)
        }
        .accessibilityAction(
            named: Text(clip.isDeleted ? PostRecordingText.restoreClip : PostRecordingText.deleteClip)
        ) {
            if clip.isDeleted {
                restoreClip(id: clip.id)
            } else {
                deleteClip(id: clip.id)
            }
        }
    }

    private func playhead(timelineWidth: CGFloat, gutter: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.accentColor)
                .stroke(.white.opacity(0.9), lineWidth: 1)
                .frame(width: 12, height: 12)
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 3, height: timelineContentHeight + 2)
                .shadow(color: .black.opacity(0.7), radius: 1)
        }
        .frame(width: 18)
        .offset(
            x: gutter + position(currentSourceTime, in: timelineWidth) - 9,
            y: -8
        )
        .contentShape(Rectangle())
        .gesture(playheadGesture(width: timelineWidth))
        .accessibilityElement()
        .accessibilityLabel(PostRecordingText.playhead)
        .accessibilityValue("Source \(PostRecordingTimelineMath.formattedTime(currentSourceTime))")
        .accessibilityHint(PostRecordingText.playheadHint)
        .accessibilityAdjustableAction { direction in
            onSeek(currentSourceTime + adjustment(for: direction, amount: 1))
        }
        .accessibilityAction(named: Text(PostRecordingText.splitClipAtPlayhead)) {
            splitClipAtPlayhead()
        }
    }

    private func playheadGesture(width: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if playheadDragOrigin == nil {
                    playheadDragOrigin = currentSourceTime
                }
                let newTime = PostRecordingTimelineMath.translatedSourceTime(
                    origin: playheadDragOrigin ?? currentSourceTime,
                    translation: value.translation.width,
                    duration: edit.sourceDuration,
                    width: width
                )
                onSeek(newTime)
            }
            .onEnded { _ in
                playheadDragOrigin = nil
            }
    }

    private func seekAndSelect(at position: CGFloat, width: CGFloat) {
        let time = PostRecordingTimelineMath.sourceTime(
            at: position,
            duration: edit.sourceDuration,
            width: width
        )
        if let id = edit.clipID(at: time) {
            selection = .clip(id)
            focusedClipID = id
        }
        onSeek(time)
    }

    private func selectClip(id: TimelineClip.ID) {
        guard let clip = edit.clip(id: id) else {
            selection = .none
            return
        }
        selection = .clip(id)
        focusedClipID = id
        if clip.isDeleted {
            return
        }
        onSeek(clip.span.start)
    }

    private func splitClipAtPlayhead() {
        guard let id = edit.splitClip(at: currentSourceTime) else {
            showEditError(PostRecordingText.splitClipFailedMessage)
            return
        }
        selection = .clip(id)
        focusedClipID = id
    }

    private func deleteClip(id: TimelineClip.ID) {
        guard let clip = edit.clip(id: id), edit.deleteClip(id: id) else {
            showEditError(PostRecordingText.deleteClipFailedMessage)
            return
        }
        selection = .clip(id)
        focusedClipID = id
        if let nextTime = edit.playableSourceTime(atOrAfter: clip.span.start) {
            onSeek(nextTime)
            return
        }
        if let lastTime = edit.lastKeptTime {
            onSeek(lastTime)
        }
    }

    private func restoreClip(id: TimelineClip.ID) {
        guard let clip = edit.clip(id: id), clip.isDeleted else {
            selection = selection.validated(for: edit)
            return
        }
        edit.restoreClip(id: id)
        selection = .clip(id)
        focusedClipID = id
        onSeek(clip.span.start)
    }

    private func showEditError(_ message: String) {
        editErrorMessage = message
        showsEditError = true
    }

    private func adjustment(
        for direction: AccessibilityAdjustmentDirection,
        amount: Double
    ) -> Double {
        switch direction {
        case .increment:
            return amount
        case .decrement:
            return -amount
        @unknown default:
            return 0
        }
    }

    private func position(_ time: Double, in width: CGFloat) -> CGFloat {
        PostRecordingTimelineMath.position(
            for: time,
            duration: edit.sourceDuration,
            width: width
        )
    }

    private func formattedRange(_ span: TimelineSpan) -> String {
        "\(PostRecordingTimelineMath.formattedTime(span.start)) to \(PostRecordingTimelineMath.formattedTime(span.end))"
    }
}

private struct ThumbnailFilmstrip: View {
    let videoURL: URL
    let duration: Double
    let count: Int

    @State private var thumbnails: [CGImage?] = []

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { index in
                thumbnail(at: index)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .task(id: count) {
            await generateThumbnails()
        }
    }

    @ViewBuilder
    private func thumbnail(at index: Int) -> some View {
        if thumbnails.indices.contains(index), let image = thumbnails[index] {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Image(systemName: "film")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func generateThumbnails() async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let times = PostRecordingTimelineMath.thumbnailSampleTimes(duration: duration, count: count)
        var generated = [CGImage?](repeating: nil, count: times.count)
        thumbnails = generated

        for (index, seconds) in times.enumerated() {
            do {
                let frame = try await generator.image(
                    at: CMTime(seconds: seconds, preferredTimescale: 600)
                )
                try Task.checkCancellation()
                generated[index] = frame.image
                thumbnails = generated
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                timelineLogger.error(
                    "Could not generate timeline thumbnail at \(seconds, privacy: .public) seconds: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

private struct TimelineClipHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 14
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
