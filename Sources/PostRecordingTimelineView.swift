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

    func validated(for edit: TimelineEdit) -> TimelineSelection {
        switch self {
        case .none:
            return .none
        case .clip(let id):
            return edit.clip(id: id) == nil ? .none : .clip(id)
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

struct PostRecordingTimelineView: View {
    let videoURL: URL
    @Binding var edit: TimelineEdit
    let currentSourceTime: Double
    @Binding var selection: TimelineSelection
    let onSeek: (Double) -> Void

    @State private var playheadDragOrigin: Double?
    @State private var showsEditError = false
    @State private var editErrorMessage = ""
    @AccessibilityFocusState private var focusedClipID: TimelineClip.ID?

    private let timelineGutter: CGFloat = 8
    private let filmstripHeight: CGFloat = 104

    var body: some View {
        VStack(spacing: 10) {
            selectionControls

            GeometryReader { geometry in
                let timelineWidth = max(1, geometry.size.width - timelineGutter * 2)

                ZStack(alignment: .topLeading) {
                    ThumbnailFilmstrip(
                        videoURL: videoURL,
                        duration: edit.sourceDuration,
                        count: PostRecordingTimelineMath.thumbnailCount(forWidth: timelineWidth)
                    )
                    .frame(width: timelineWidth, height: filmstripHeight)
                    .offset(x: timelineGutter)
                    .accessibilityHidden(true)

                    ForEach(edit.clips) { clip in
                        clipSegment(
                            clip,
                            timelineWidth: timelineWidth,
                            gutter: timelineGutter
                        )
                    }

                    timelineGestureTarget(width: timelineWidth)
                        .offset(x: timelineGutter)

                    playhead(timelineWidth: timelineWidth, gutter: timelineGutter)
                }
                .contextMenu {
                    timelineContextMenu
                }
            }
            .frame(height: filmstripHeight + 14)

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
            }
        }
    }

    private var selectionDescription: String {
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
                .frame(width: 3, height: filmstripHeight + 2)
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
