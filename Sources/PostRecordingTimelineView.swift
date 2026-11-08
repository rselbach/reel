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

/// Maps source time to positions across the timeline. Deleted clips get a
/// quarter of their share, but at least enough to click, so kept footage
/// gets the room and a long cut does not dominate the strip.
struct TimelineScale: Equatable {
    static let deletedShare: CGFloat = 0.25
    static let minimumDeletedWidth: CGFloat = 28

    private struct Segment: Equatable {
        let span: TimelineSpan
        let x: CGFloat
        let width: CGFloat
    }

    let width: CGFloat
    private let segments: [Segment]

    init(edit: TimelineEdit, width: CGFloat) {
        let width = width.isFinite ? max(1, width) : 1
        self.width = width
        let duration = edit.sourceDuration
        let proportional = { (span: TimelineSpan) in width * CGFloat(span.duration / duration) }
        let deletedWidths = edit.clips.map { clip -> CGFloat? in
            guard clip.isDeleted else { return nil }
            let share = proportional(clip.span)
            return min(share, max(Self.minimumDeletedWidth, share * Self.deletedShare))
        }
        let keptWidth = max(0, width - deletedWidths.reduce(0) { $0 + ($1 ?? 0) })
        let keptDuration = edit.editedDuration

        var x: CGFloat = 0
        var segments: [Segment] = []
        for (clip, deletedWidth) in zip(edit.clips, deletedWidths) {
            let segmentWidth =
                deletedWidth
                ?? (keptDuration > 0 ? keptWidth * CGFloat(clip.span.duration / keptDuration) : 0)
            segments.append(Segment(span: clip.span, x: x, width: segmentWidth))
            x += segmentWidth
        }
        self.segments = segments
    }

    func position(_ time: Double) -> CGFloat {
        guard time.isFinite, let first = segments.first, let last = segments.last else { return 0 }
        guard time > first.span.start else { return 0 }
        guard time < last.span.end else { return width }
        let segment = segments.first { time < $0.span.end } ?? last
        let progress = (time - segment.span.start) / segment.span.duration
        return segment.x + segment.width * CGFloat(progress)
    }

    func sourceTime(at position: CGFloat) -> Double {
        guard position.isFinite, let first = segments.first, let last = segments.last else { return 0 }
        guard position > 0 else { return first.span.start }
        guard position < width else { return last.span.end }
        let segment = segments.first { position < $0.x + $0.width } ?? last
        guard segment.width > 0 else { return segment.span.start }
        let progress = Double((position - segment.x) / segment.width)
        return segment.span.start + segment.span.duration * min(max(0, progress), 1)
    }

    func translatedSourceTime(origin: Double, translation: CGFloat) -> Double {
        guard origin.isFinite else { return 0 }
        return sourceTime(at: position(origin) + translation)
    }

    func width(for span: TimelineSpan) -> CGFloat {
        max(0, position(span.end) - position(span.start))
    }
}

private enum ZoomResizeEdge: Equatable {
    case leading
    case trailing
}

/// A trim handle being dragged. The timeline shows `draft` until the drag
/// ends, so the whole drag becomes a single edit.
private struct TrimDrag {
    let edge: TrimEdge
    let original: TimelineEdit
    var draft: TimelineEdit
}

private struct ZoomResizeState {
    let sceneID: ZoomScene.ID
    let edge: ZoomResizeEdge
    let originalSpan: TimelineSpan
    var currentSpan: TimelineSpan
}

private struct ZoomSceneSettingsPopover: View {
    @Binding var settings: ZoomSceneSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Zoom level")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(settings.level.label)
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(
                value: zoomScale,
                in: ZoomSceneSettings.Level.minimumScale...ZoomSceneSettings.Level.maximumScale,
                step: ZoomSceneSettings.Level.sliderStep
            )
            .accessibilityLabel("Zoom level")
            .accessibilityValue(settings.level.accessibilityLabel)

            Text("Transition speed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Transition speed", selection: $settings.transitionSpeed) {
                ForEach(ZoomSceneSettings.TransitionSpeed.allCases, id: \.self) { speed in
                    Text(speed.label).tag(speed)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .controlSize(.small)
        .padding()
        .frame(width: 280)
    }

    private var zoomScale: Binding<Double> {
        Binding(
            get: { settings.level.scale },
            set: { settings.level = ZoomSceneSettings.Level(scale: $0) }
        )
    }
}

struct PostRecordingTimelineView: View {
    let videoURL: URL
    @Binding var edit: TimelineEdit
    /// Read-only here, but a binding so the Split shortcut sees the current
    /// time: SwiftUI keeps the action from when a shortcut was registered,
    /// and a plain value in it would stay at the time Split was enabled.
    @Binding var currentSourceTime: Double
    @Binding var selection: TimelineSelection
    let onSeek: (Double) -> Void
    /// Shows a source frame without moving it to kept footage, so a trim
    /// handle can show the frame it is moving over. Nil ends the scrub.
    let onScrub: (Double?) -> Void
    let onSelectZoomScene: (ZoomScene.ID) -> Void

    @State private var playheadDragOrigin: Double?
    @State private var trimDrag: TrimDrag?
    @State private var zoomDraftStart: Double?
    @State private var zoomDraftSpan: TimelineSpan?
    @State private var zoomResizeState: ZoomResizeState?
    @State private var zoomSettingsPopoverSceneID: ZoomScene.ID?
    /// The trim frame turns yellow only while the pointer is over the
    /// timeline or a handle is dragged, so the clip does not look selected.
    @State private var isHoveringTimeline = false
    @State private var showsEditError = false
    @State private var editErrorMessage = ""
    @AccessibilityFocusState private var focusedClipID: TimelineClip.ID?
    @AccessibilityFocusState private var focusedZoomSceneID: ZoomScene.ID?

    private let timelineGutter: CGFloat = 14
    private let trimHandleWidth: CGFloat = 12
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
                // Laid out from the edit before a trim drag, so the strip holds
                // still under the handle while it moves.
                let scale = TimelineScale(
                    edit: trimDrag?.original ?? edit,
                    width: geometry.size.width - timelineGutter * 2
                )

                ZStack(alignment: .topLeading) {
                    zoomLane(scale: scale)
                        .offset(x: timelineGutter)

                    ThumbnailFilmstrip(
                        videoURL: videoURL,
                        duration: edit.sourceDuration,
                        segments: displayedEdit.clips.map { ($0.span, scale.width(for: $0.span)) },
                        sampleCount: PostRecordingTimelineMath.thumbnailCount(forWidth: scale.width) * 2
                    )
                    .frame(width: scale.width, height: filmstripHeight)
                    .offset(x: timelineGutter, y: zoomLaneHeight + laneSpacing)
                    .accessibilityHidden(true)

                    ForEach(displayedEdit.clips) { clip in
                        clipSegment(clip, scale: scale, gutter: timelineGutter)
                            .offset(y: zoomLaneHeight + laneSpacing)
                    }

                    timelineGestureTarget(scale: scale)
                        .offset(x: timelineGutter, y: zoomLaneHeight + laneSpacing)

                    keptFrame(scale: scale, gutter: timelineGutter)
                        .offset(y: zoomLaneHeight + laneSpacing)

                    playhead(scale: scale, gutter: timelineGutter)

                    // Above the playhead, which starts on the start handle;
                    // the playhead stays reachable by its knob.
                    trimHandle(.start, scale: scale, gutter: timelineGutter)
                        .offset(y: zoomLaneHeight + laneSpacing)
                    trimHandle(.end, scale: scale, gutter: timelineGutter)
                        .offset(y: zoomLaneHeight + laneSpacing)
                }
                .contextMenu {
                    timelineContextMenu
                }
                .onHover { isHoveringTimeline = $0 }
                .animation(.easeOut(duration: 0.15), value: showsTrimFrame)
            }
            .frame(height: timelineContentHeight + 14)
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
                // A space keeps the line's height when there is nothing to say.
                Text(selectionDescription.isEmpty ? " " : selectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if case .clip(let id) = selection, let clip = edit.clip(id: id) {
                if clip.isDeleted {
                    Button(PostRecordingText.restoreClip) {
                        restoreClip(id: id)
                    }
                } else {
                    // SwiftUI keeps the action from when a keyboard shortcut
                    // was registered, so an ID captured here would still name
                    // the first clip selected; deleteSelection reads the
                    // selection when the key is pressed.
                    Button(PostRecordingText.deleteClip, role: .destructive) {
                        deleteSelection()
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!edit.canDeleteClip(id: id))
                }
            } else if case .zoomScene(let id) = selection, edit.zoomScene(id: id) != nil {
                Button(PostRecordingText.zoomSettings) {
                    zoomSettingsPopoverSceneID = id
                }
            }

            Button {
                splitClipAtPlayhead()
            } label: {
                Label(PostRecordingText.split, systemImage: "scissors")
            }
            .keyboardShortcut("b", modifiers: .command)
            .help(PostRecordingText.splitHelp)
            .disabled(!edit.canSplit(at: currentSourceTime))
        }
        .background {
            selectionShortcuts
        }
    }

    /// Escape clears the selection, and Delete removes a selected zoom
    /// scene, whose own trash button is its visible delete control.
    private var selectionShortcuts: some View {
        ZStack {
            Button("") {
                selection = .none
            }
            .keyboardShortcut(.cancelAction)
            .disabled(selection == .none)

            if case .zoomScene = selection {
                Button("") {
                    deleteSelection()
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var selectionDescription: String {
        if case .zoomScene(let id) = selection, let scene = edit.zoomScene(id: id) {
            return
                "\(scene.settings.level.label) zoom, \(formattedLength(scene.span)). Drag the circle in the video to aim it."
        }
        guard case .clip(let id) = selection, let clip = edit.clip(id: id) else {
            // The how-to stays only until the first edit.
            return edit.hasMeaningfulChanges ? "" : PostRecordingText.timelineHelp
        }
        if clip.isDeleted {
            return "Deleted clip, \(formattedLength(clip.span)). Restore it to keep it."
        }
        guard edit.canDeleteClip(id: id) else {
            return "Clip, \(formattedLength(clip.span))."
        }
        return "Clip, \(formattedLength(clip.span)). Press Delete to remove it."
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

    private func timelineGestureTarget(scale: TimelineScale) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: scale.width, height: filmstripHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.width) >= 3 else { return }
                        seekAndSelect(at: value.location.x, scale: scale)
                    }
                    .onEnded { value in
                        seekAndSelect(at: value.location.x, scale: scale)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(PostRecordingText.timeline)
            .accessibilityValue(selectionDescription)
            .accessibilityHint(PostRecordingText.timelineHelp)
            .accessibilityAction(named: Text(PostRecordingText.splitClipAtPlayhead)) {
                splitClipAtPlayhead()
            }
    }

    private func zoomLane(scale: TimelineScale) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(zoomLaneGesture(scale: scale))

            if let zoomDraftSpan {
                zoomBlock(
                    span: zoomDraftSpan,
                    level: ZoomSceneSettings.standard.level,
                    scale: scale,
                    isSelected: false
                )
                .offset(x: scale.position(zoomDraftSpan.start))
                .opacity(0.65)
                .allowsHitTesting(false)
            }

            ForEach(edit.zoomScenes) { scene in
                zoomSceneBlock(scene, scale: scale)
            }

            if edit.zoomScenes.isEmpty, zoomDraftSpan == nil {
                Text(PostRecordingText.zoomLaneEmpty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: scale.width, height: zoomLaneHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PostRecordingText.zoomLane)
        .accessibilityValue("\(edit.zoomScenes.count) zoom scenes")
        .accessibilityHint(PostRecordingText.zoomLaneHint)
        .accessibilityAction(named: Text(PostRecordingText.addZoomSceneAtPlayhead)) {
            addZoomSceneAtPlayhead()
        }
    }

    private func zoomSceneBlock(_ scene: ZoomScene, scale: TimelineScale) -> some View {
        let isSelected = selection == .zoomScene(scene.id)
        let span = displayedZoomSpan(for: scene)
        let blockWidth = scale.width(for: span)

        return zoomBlock(
            span: span,
            level: scene.settings.level,
            scale: scale,
            isSelected: isSelected
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // A second click on the selected scene opens its settings.
            if isSelected {
                zoomSettingsPopoverSceneID = scene.id
            } else {
                selectZoomScene(scene.id)
            }
        }
        .popover(
            isPresented: zoomSettingsPopoverPresented(for: scene.id),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            ZoomSceneSettingsPopover(settings: zoomSettingsBinding(for: scene.id))
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
                    scale: scale
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
                    scale: scale
                )
                .offset(x: 8)
            }
        }
        .contextMenu {
            Button(PostRecordingText.deleteZoomScene, role: .destructive) {
                removeZoomScene(id: scene.id)
            }
        }
        .offset(x: scale.position(span.start))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PostRecordingText.zoomScene)
        .accessibilityValue(
            "\(scene.settings.level.accessibilityLabel), \(formattedLength(span))"
        )
        .accessibilityHint("Select to adjust zoom and focal point. Drag either edge to resize.")
        .accessibilityFocused($focusedZoomSceneID, equals: scene.id)
        .accessibilityAction {
            selectZoomScene(scene.id)
        }
        .accessibilityAction(named: Text(PostRecordingText.deleteZoomScene)) {
            removeZoomScene(id: scene.id)
        }
    }

    private func zoomSettingsPopoverPresented(for sceneID: ZoomScene.ID) -> Binding<Bool> {
        Binding(
            get: {
                zoomSettingsPopoverSceneID == sceneID
                    && selection == .zoomScene(sceneID)
                    && edit.zoomScene(id: sceneID) != nil
            },
            set: { isPresented in
                guard !isPresented, zoomSettingsPopoverSceneID == sceneID else { return }
                zoomSettingsPopoverSceneID = nil
            }
        )
    }

    private func selectZoomScene(_ sceneID: ZoomScene.ID) {
        guard edit.zoomScene(id: sceneID) != nil else { return }
        selection = .zoomScene(sceneID)
        focusedZoomSceneID = sceneID
        onSelectZoomScene(sceneID)
    }

    private func zoomSettingsBinding(for sceneID: ZoomScene.ID) -> Binding<ZoomSceneSettings> {
        Binding(
            get: {
                edit.zoomScene(id: sceneID)?.settings ?? .standard
            },
            set: { settings in
                do {
                    try edit.setZoomSettings(settings, for: sceneID)
                } catch {
                    showEditError(error.localizedDescription)
                }
            }
        )
    }

    private func displayedZoomSpan(for scene: ZoomScene) -> TimelineSpan {
        guard zoomResizeState?.sceneID == scene.id else { return scene.span }
        return zoomResizeState?.currentSpan ?? scene.span
    }

    private func zoomResizeHandle(
        scene: ZoomScene,
        span: TimelineSpan,
        edge: ZoomResizeEdge,
        scale: TimelineScale
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
        .gesture(zoomResizeGesture(scene: scene, edge: edge, scale: scale))
        .accessibilityElement()
        .accessibilityLabel(edge == .leading ? "Zoom start" : "Zoom end")
        .accessibilityValue(formattedEditedTime(edge == .leading ? span.start : span.end))
        .accessibilityHint("Drag horizontally to resize the zoom scene.")
        .accessibilityAdjustableAction { direction in
            adjustZoomEdge(scene: scene, edge: edge, direction: direction)
        }
    }

    private func zoomResizeGesture(
        scene: ZoomScene,
        edge: ZoomResizeEdge,
        scale: TimelineScale
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
                let originalEdge = edge == .leading ? state.originalSpan.start : state.originalSpan.end
                let seconds =
                    scale.translatedSourceTime(origin: originalEdge, translation: value.translation.width)
                    - originalEdge
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

    private func zoomBlock(
        span: TimelineSpan,
        level: ZoomSceneSettings.Level,
        scale: TimelineScale,
        isSelected: Bool
    ) -> some View {
        let blockWidth = scale.width(for: span)
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(isSelected ? 0.85 : 0.62))
            if blockWidth >= 60 {
                Text("Zoom \(level.label)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            RoundedRectangle(cornerRadius: 5)
                .stroke(.white.opacity(isSelected ? 1 : 0.75), lineWidth: isSelected ? 2 : 1)
        }
        .frame(width: max(3, blockWidth), height: zoomLaneHeight)
    }

    private func zoomLaneGesture(scale: TimelineScale) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = scale.sourceTime(at: value.location.x)
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
                    onSeek(scale.sourceTime(at: value.location.x))
                    return
                }
                addZoomScene(span: span)
            }
    }

    private func addZoomScene(span: TimelineSpan) {
        do {
            let id = try edit.addZoomScene(span: span)
            selectZoomScene(id)
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
        if zoomSettingsPopoverSceneID == id {
            zoomSettingsPopoverSceneID = nil
        }
        edit.removeZoomScene(id: id)
        selection = .none
    }

    private func clipSegment(
        _ clip: TimelineClip,
        scale: TimelineScale,
        gutter: CGFloat
    ) -> some View {
        let width = scale.width(for: clip.span)
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
        .offset(x: gutter + scale.position(clip.span.start))
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(clip.isDeleted ? PostRecordingText.deletedClip : PostRecordingText.clip)
        .accessibilityValue(formattedLength(clip.span))
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

    private var showsTrimFrame: Bool {
        isHoveringTimeline || trimDrag != nil
    }

    /// The edit as shown, including a trim still being dragged.
    private var displayedEdit: TimelineEdit {
        trimDrag?.draft ?? edit
    }

    private func keptEdge(_ edge: TrimEdge, of edit: TimelineEdit) -> Double {
        switch edge {
        case .start:
            return edit.firstKeptTime ?? 0
        case .end:
            return edit.lastKeptTime ?? edit.sourceDuration
        }
    }

    /// Outlines the kept recording from the start handle to the end handle.
    private func keptFrame(scale: TimelineScale, gutter: CGFloat) -> some View {
        let start = scale.position(keptEdge(.start, of: displayedEdit))
        let end = scale.position(keptEdge(.end, of: displayedEdit))
        return VStack(spacing: 0) {
            Rectangle().frame(height: 3)
            Spacer(minLength: 0)
            Rectangle().frame(height: 3)
        }
        .foregroundStyle(Color.yellow)
        .opacity(showsTrimFrame ? 1 : 0)
        .frame(width: max(0, end - start), height: filmstripHeight)
        .offset(x: gutter + start)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func trimHandle(_ edge: TrimEdge, scale: TimelineScale, gutter: CGFloat) -> some View {
        let x = gutter + scale.position(keptEdge(edge, of: displayedEdit))
        let trimmed =
            edge == .start
            ? keptEdge(.start, of: edit)
            : edit.sourceDuration - keptEdge(.end, of: edit)
        let radius: CGFloat = 5

        return UnevenRoundedRectangle(
            topLeadingRadius: edge == .start ? radius : 0,
            bottomLeadingRadius: edge == .start ? radius : 0,
            bottomTrailingRadius: edge == .end ? radius : 0,
            topTrailingRadius: edge == .end ? radius : 0
        )
        .fill(showsTrimFrame ? Color.yellow : Color.gray.opacity(0.6))
        .overlay {
            Image(systemName: edge == .start ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(showsTrimFrame ? .black.opacity(0.65) : .white.opacity(0.85))
        }
        .frame(width: trimHandleWidth, height: filmstripHeight)
        .contentShape(Rectangle())
        .offset(x: edge == .start ? x - trimHandleWidth : x)
        .gesture(trimGesture(edge, scale: scale))
        .help(PostRecordingText.trimHandleHelp)
        .accessibilityElement()
        .accessibilityLabel(edge == .start ? PostRecordingText.trimStart : PostRecordingText.trimEnd)
        .accessibilityValue("\(PostRecordingTimelineMath.formattedTime(trimmed)) trimmed")
        .accessibilityHint(PostRecordingText.trimHandleHelp)
        .accessibilityAdjustableAction { direction in
            let inward = edge == .start ? 0.1 : -0.1
            trim(edge, to: keptEdge(edge, of: edit) + adjustment(for: direction, amount: inward))
        }
    }

    private func trimGesture(_ edge: TrimEdge, scale: TimelineScale) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let original = trimDrag?.original ?? edit
                var draft = original
                draft.trim(
                    edge,
                    to: scale.translatedSourceTime(
                        origin: keptEdge(edge, of: original),
                        translation: value.translation.width
                    )
                )
                trimDrag = TrimDrag(edge: edge, original: original, draft: draft)
                onScrub(keptEdge(edge, of: draft))
            }
            .onEnded { _ in
                guard let trimDrag else { return }
                self.trimDrag = nil
                onScrub(nil)
                if trimDrag.draft != edit {
                    edit = trimDrag.draft
                    selection = selection.validated(for: edit)
                }
                onSeek(keptEdge(edge, of: edit))
            }
    }

    private func trim(_ edge: TrimEdge, to time: Double) {
        edit.trim(edge, to: time)
        selection = selection.validated(for: edit)
        onSeek(keptEdge(edge, of: edit))
    }

    private func playhead(scale: TimelineScale, gutter: CGFloat) -> some View {
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
        // Shaped before the offset so the grab area moves with the playhead
        // instead of staying where the timeline starts.
        .contentShape(Rectangle())
        .offset(
            x: gutter + scale.position(currentSourceTime) - 9,
            y: -8
        )
        .gesture(playheadGesture(scale: scale))
        .accessibilityElement()
        .accessibilityLabel(PostRecordingText.playhead)
        .accessibilityValue(formattedEditedTime(currentSourceTime))
        .accessibilityHint(PostRecordingText.playheadHint)
        .accessibilityAdjustableAction { direction in
            onSeek(currentSourceTime + adjustment(for: direction, amount: 1))
        }
        .accessibilityAction(named: Text(PostRecordingText.splitClipAtPlayhead)) {
            splitClipAtPlayhead()
        }
    }

    private func playheadGesture(scale: TimelineScale) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if playheadDragOrigin == nil {
                    playheadDragOrigin = currentSourceTime
                }
                let newTime = scale.translatedSourceTime(
                    origin: playheadDragOrigin ?? currentSourceTime,
                    translation: value.translation.width
                )
                onSeek(newTime)
            }
            .onEnded { _ in
                playheadDragOrigin = nil
            }
    }

    private func seekAndSelect(at position: CGFloat, scale: TimelineScale) {
        let time = scale.sourceTime(at: position)
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

    /// Times read as the preview's clock does, in the edited recording, so
    /// the timeline never shows a second clock in source time.
    private func formattedEditedTime(_ sourceTime: Double) -> String {
        PostRecordingTimelineMath.formattedTime(
            PostRecordingTimelineMath.editedTime(forSourceTime: sourceTime, edit: edit)
        )
    }

    private func formattedLength(_ span: TimelineSpan) -> String {
        "\(PostRecordingTimelineMath.formattedTime(span.duration)) long"
    }
}

/// Frames from the recording behind the timeline. Each clip shows frames
/// from its own footage across its own width, so a narrowed deleted clip
/// does not shift the frames beside it.
private struct ThumbnailFilmstrip: View {
    let videoURL: URL
    let duration: Double
    /// Each clip's footage and displayed width, left to right.
    let segments: [(span: TimelineSpan, width: CGFloat)]
    let sampleCount: Int

    @State private var thumbnails: [CGImage?] = []

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                let cells = max(
                    1,
                    Int((segment.width / PostRecordingTimelineMath.preferredThumbnailWidth).rounded())
                )
                HStack(spacing: 1) {
                    ForEach(0..<cells, id: \.self) { cell in
                        let progress = (Double(cell) + 0.5) / Double(cells)
                        thumbnail(at: sampleIndex(for: segment.span.start + segment.span.duration * progress))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                }
                .frame(width: segment.width)
                .clipped()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .task(id: sampleCount) {
            await generateThumbnails()
        }
    }

    private func sampleIndex(for time: Double) -> Int {
        guard sampleCount > 0, duration > 0 else { return 0 }
        return min(sampleCount - 1, max(0, Int(time / duration * Double(sampleCount))))
    }

    @ViewBuilder
    private func thumbnail(at index: Int) -> some View {
        if thumbnails.indices.contains(index), let image = thumbnails[index] {
            // A filling image reports its full width to the HStack, which
            // would push the strip past the timeline's edges and out of step
            // with the clip boundaries drawn over it; an overlay cannot.
            Color.clear
                .overlay {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
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
        // Close to the asked time rather than the nearest keyframe, which
        // could show the same frame in neighboring cells.
        let tolerance = CMTime(seconds: duration / Double(max(1, sampleCount)) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = PostRecordingTimelineMath.thumbnailSampleTimes(duration: duration, count: sampleCount)
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
            // Each 45-degree line is cut to the clip's width, so it never
            // stripes the kept footage beside a deleted clip.
            let start = max(0, rect.minX - x)
            let end = min(rect.height, rect.maxX - x)
            if start < end {
                path.move(to: CGPoint(x: x + start, y: rect.maxY - start))
                path.addLine(to: CGPoint(x: x + end, y: rect.maxY - end))
            }
            x += spacing
        }
        return path
    }
}
