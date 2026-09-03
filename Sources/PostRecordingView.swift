import AVKit
import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel",
    category: "PostRecordingView"
)

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}

enum PlaybackIntent: Equatable {
    case paused
    case playing
}

enum PostRecordingText {
    static let loading = "Loading..."
    static let revealInFinder = "Reveal in Finder"
    static let copy = "Copy"
    static let copied = "Copied!"
    static let dragHint = "Drag this recording into Slack, Mail, or Finder"
    static let delete = "Move to Trash"
    static let saveEdited = "Save Edited..."
    static let timeline = "Timeline"
    static let timelineHelp = "Drag the playhead to seek. Right-click the timeline to split at the playhead."
    static let sourceTimeline = "Source timeline"
    static let clearSelection = "Clear Selection"
    static let splitClipAtPlayhead = "Split Clip at Playhead"
    static let deleteClip = "Delete Clip"
    static let restoreClip = "Restore Clip"
    static let clip = "Clip"
    static let deletedClip = "Deleted clip"
    static let deleted = "Deleted"
    static let clipHint = "Select this clip to delete or restore it."
    static let zoomLane = "Zoom lane"
    static let zoomLaneEmpty = "Drag to add a 150% zoom"
    static let zoomLaneHint = "Drag empty space to create a zoom scene lasting at least 0.25 seconds."
    static let zoomScene = "Zoom scene"
    static let zoomSceneHint = "Select this scene to set its focal point."
    static let addZoomSceneAtPlayhead = "Add Zoom Scene at Playhead"
    static let deleteZoomScene = "Delete Zoom Scene"
    static let editClipFailedTitle = "Could Not Edit Timeline"
    static let splitClipFailedMessage =
        "Move the playhead at least 0.05 seconds from either edge of a clip, then split again."
    static let deleteClipFailedMessage =
        "The edited recording must keep at least 0.5 seconds."
    static let playhead = "Playhead"
    static let playheadHint = "Drag to seek. Right-click the timeline to split here."
    static let backFiveSeconds = "Back 5 seconds"
    static let forwardFiveSeconds = "Forward 5 seconds"
    static let play = "Play"
    static let pause = "Pause"
    static let editedPlaybackTime = "Edited playback time"
    static let exportSmaller = "Smaller Copy..."
    static let exportGIF = "GIF..."
    static let exportGIFHelp = "Silent, looping, capped in size and frame count for README and issue embeds."
    static let exportSmallerHelp = "Re-encodes at 720p for sharing in chat, issues, and pull requests."
    static let editNote =
        "Deleted clips are skipped, and zoom scenes are applied during playback and export."
    static let done = "Done"
    static let recordAgain = "Record Again"
    static let changeTarget = "Change Target..."
    static let deleteConfirmationTitle = "Move recording to Trash?"
    static let deleteConfirmationMessage = "You can recover it from the Trash."
}

enum GIFExport {
    static let frameRate: Double = 12
    static let maxWidth: CGFloat = 800
    static let maxFrames = 300

    static func frames(edit: TimelineEdit) -> (times: [Double], delay: Double) {
        let duration = edit.editedDuration
        guard duration > 0 else { return ([], 1 / frameRate) }

        let ideal = Int((duration * frameRate).rounded())
        let count = min(maxFrames, max(1, ideal))
        let spacing = duration / Double(count)

        let times = (0..<count).compactMap {
            edit.sourceTime(forEditedTime: spacing * Double($0))
        }
        return (times, spacing)
    }
}

enum ExportFileNaming {
    static func temporaryURL(for outputURL: URL, identifier: String = UUID().uuidString) -> URL {
        let fileExtension = outputURL.pathExtension
        return
            outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputURL.deletingPathExtension().lastPathComponent)-\(identifier).\(fileExtension)"
            )
    }
}

enum PostRecordingLogic {
    static func canExport(edit: TimelineEdit?, isExporting: Bool) -> Bool {
        guard let edit else { return false }
        return edit.editedDuration > 0 && !isExporting
    }
}

struct PostRecordingView: View {
    let videoURL: URL
    let onDismiss: () -> Void
    let onRevealInFinder: () -> Void
    let onRecordAgain: () -> Void
    let onChangeTarget: () -> Void
    let onDelete: () -> Void

    @State private var player: AVPlayer?
    /// Loaded with the preview so future cursor-aware effects can use the
    /// recording's source-time positions without reopening the asset.
    @State private var cursorTimeline = CursorTimeline.empty
    @State private var timeObserver: Any?
    @State private var deletedClipBoundaryObservers: [Any] = []
    @State private var zoomCompositionTask: Task<Void, Never>?
    @State private var isCleanedUp = false
    @State private var edit: TimelineEdit?
    @State private var currentTime: Double = 0
    @State private var playbackIntent: PlaybackIntent = .paused
    @State private var timelineSelection: TimelineSelection = .none
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var showDeleteConfirmation = false
    @State private var exportError: String?
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 14) {
            if case .zoomScene(let sceneID) = timelineSelection,
                let scene = edit?.zoomScene(id: sceneID)
            {
                ZoomFocusEditor(
                    videoURL: videoURL,
                    sourceTime: scene.span.start + scene.span.duration / 2,
                    focalPoint: scene.focalPoint,
                    scale: scene.settings.level.scale,
                    onChange: { point in
                        updateZoomFocalPoint(point, sceneID: sceneID)
                    }
                )
                .frame(minWidth: 700, minHeight: 300, maxHeight: .infinity)
                .layoutPriority(1)
            } else if let player {
                VideoPlayerView(player: player)
                    .frame(minWidth: 700, minHeight: 300, maxHeight: .infinity)
                    .layoutPriority(1)
            } else {
                ProgressView(PostRecordingText.loading)
                    .frame(minWidth: 700, minHeight: 300, maxHeight: .infinity)
                    .layoutPriority(1)
            }

            PlaybackTransport(
                intent: playbackIntent,
                currentTime: editedCurrentTime,
                duration: edit?.editedDuration ?? 0,
                isEnabled: player != nil && edit != nil && !isExporting && !isEditingZoomFocus,
                onTogglePlayback: togglePlayback,
                onSkip: skipEditedSeconds
            )
            .padding(.horizontal)

            if let loadedEdit = edit {
                PostRecordingTimelineView(
                    videoURL: videoURL,
                    edit: Binding(
                        get: { self.edit ?? loadedEdit },
                        set: { self.edit = $0 }
                    ),
                    currentSourceTime: currentTime,
                    selection: $timelineSelection,
                    onSeek: seekPlayer,
                    onSelectZoomScene: selectZoomScene
                )
                .padding(.horizontal)
                .disabled(isExporting)

                if hasEdits {
                    Text(PostRecordingText.editNote)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = exportError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                    Text(videoURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .onDrag {
                    NSItemProvider(contentsOf: videoURL) ?? NSItemProvider()
                }
                .allowsHitTesting(!isExporting)
                .help(PostRecordingText.dragHint)

                Button(justCopied ? PostRecordingText.copied : PostRecordingText.copy) {
                    copyToPasteboard()
                }
                .disabled(isExporting)

                Spacer()

                Button(PostRecordingText.revealInFinder) {
                    onRevealInFinder()
                }
                .disabled(isExporting)

                Button(PostRecordingText.delete, role: .destructive) {
                    showDeleteConfirmation = true
                }
                .foregroundColor(.red)
                .disabled(isExporting)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button(PostRecordingText.recordAgain) {
                    onRecordAgain()
                }
                .disabled(isExporting)

                Button(PostRecordingText.changeTarget) {
                    onChangeTarget()
                }
                .disabled(isExporting)

                Spacer()

                if hasEdits {
                    Button(PostRecordingText.saveEdited) {
                        startVideoExport(
                            quality: .source,
                            suffix: "edited"
                        )
                    }
                    .disabled(!canExport)
                }

                Button(PostRecordingText.exportSmaller) {
                    startVideoExport(
                        quality: .p720,
                        suffix: "720p"
                    )
                }
                .disabled(!canExport)
                .help(PostRecordingText.exportSmallerHelp)

                Button(PostRecordingText.exportGIF) {
                    startGIFExport()
                }
                .disabled(!canExport)
                .help(PostRecordingText.exportGIFHelp)

                if isExporting {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Button(PostRecordingText.done) {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 780, minHeight: 700)
        .alert(PostRecordingText.deleteConfirmationTitle, isPresented: $showDeleteConfirmation) {
            Button(PostRecordingText.delete, role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PostRecordingText.deleteConfirmationMessage)
        }
        .onAppear {
            setupPlayer()
        }
        .onChange(of: edit) { previousEdit, changedEdit in
            guard let changedEdit else {
                timelineSelection = .none
                player?.currentItem?.videoComposition = nil
                return
            }
            timelineSelection = timelineSelection.validated(for: changedEdit)
            if previousEdit?.clips != changedEdit.clips {
                refreshDeletedClipBoundaryObservers()
            }
            if previousEdit?.zoomScenes != changedEdit.zoomScenes {
                refreshZoomPreviewComposition(scenes: changedEdit.zoomScenes)
            }
        }
        .onChange(of: timelineSelection) { previousSelection, changedSelection in
            if case .zoomScene = previousSelection, case .zoomScene = changedSelection {
                return
            }
            guard case .zoomScene = previousSelection else { return }
            seekPlayer(to: currentTime)
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            isExporting = false
            cleanupPlayer()
        }
    }

    private var hasEdits: Bool {
        edit?.hasMeaningfulChanges == true
    }

    private var canExport: Bool {
        PostRecordingLogic.canExport(edit: edit, isExporting: isExporting)
    }

    private var isEditingZoomFocus: Bool {
        guard case .zoomScene(let id) = timelineSelection else { return false }
        return edit?.zoomScene(id: id) != nil
    }

    private var editedCurrentTime: Double {
        guard let edit else { return 0 }
        return PostRecordingTimelineMath.editedTime(forSourceTime: currentTime, edit: edit)
    }

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([videoURL as NSURL]) else {
            exportError = "Could not copy the recording to the clipboard."
            justCopied = false
            return
        }
        exportError = nil
        justCopied = true
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            justCopied = false
        }
    }

    private func cleanupPlayer() {
        isCleanedUp = true
        pausePlayback()

        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let player {
            for observer in deletedClipBoundaryObservers {
                player.removeTimeObserver(observer)
            }
        }
        deletedClipBoundaryObservers = []
        zoomCompositionTask?.cancel()
        zoomCompositionTask = nil
        timeObserver = nil
        player = nil
    }

    private func setupPlayer() {
        isCleanedUp = false
        let asset = AVURLAsset(url: videoURL)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer

        Task { @MainActor [self] in
            do {
                let durationTime = try await asset.load(.duration)
                guard !isCleanedUp else { return }
                let seconds = CMTimeGetSeconds(durationTime)
                if let loadedEdit = TimelineEdit(sourceDuration: seconds) {
                    edit = loadedEdit
                    currentTime = loadedEdit.firstKeptTime ?? 0
                }
            } catch {
                guard !isCleanedUp else { return }
                exportError = "Unable to load recording duration: \(error.localizedDescription)"
            }
        }

        Task { @MainActor [self] in
            do {
                let loadedTimeline = try await CursorMetadataTrack.load(from: videoURL)
                guard !isCleanedUp else { return }
                cursorTimeline = loadedTimeline
            } catch {
                guard !isCleanedUp else { return }
                logger.warning("Unable to load cursor positions: \(error.localizedDescription)")
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak newPlayer] time in
            guard newPlayer != nil else { return }
            Task { @MainActor [self] in
                guard !isCleanedUp else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite, let edit else { return }
                guard seconds < edit.sourceDuration else {
                    newPlayer?.pause()
                    playbackIntent = .paused
                    currentTime = edit.lastKeptTime ?? edit.sourceDuration
                    return
                }
                guard let playableTime = edit.playableSourceTime(atOrAfter: seconds) else {
                    newPlayer?.pause()
                    playbackIntent = .paused
                    currentTime = edit.lastKeptTime ?? edit.sourceDuration
                    return
                }
                currentTime = playableTime
                if playableTime > seconds + 0.001 {
                    newPlayer?.seek(
                        to: CMTime(seconds: playableTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
            }
        }
    }

    private func refreshDeletedClipBoundaryObservers() {
        guard let player else { return }
        for observer in deletedClipBoundaryObservers {
            player.removeTimeObserver(observer)
        }
        deletedClipBoundaryObservers = []
        guard let edit else { return }

        deletedClipBoundaryObservers = edit.deletedClips.map { clip in
            let boundary = NSValue(time: CMTime(seconds: clip.span.start, preferredTimescale: 600))
            return player.addBoundaryTimeObserver(forTimes: [boundary], queue: .main) { [weak player] in
                Task { @MainActor [self] in
                    guard
                        !isCleanedUp,
                        let player,
                        let deletedClip = self.edit?.deletedClips.first(where: { $0.id == clip.id })
                    else { return }
                    let seconds = CMTimeGetSeconds(player.currentTime())
                    guard
                        seconds >= deletedClip.span.start - 0.05,
                        seconds < deletedClip.span.end
                    else { return }
                    guard
                        let nextTime = self.edit?.playableSourceTime(
                            atOrAfter: deletedClip.span.start
                        )
                    else {
                        player.pause()
                        playbackIntent = .paused
                        currentTime = self.edit?.lastKeptTime ?? deletedClip.span.start
                        return
                    }
                    currentTime = nextTime
                    player.seek(
                        to: CMTime(seconds: nextTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
            }
        }
    }

    private func refreshZoomPreviewComposition(scenes: [ZoomScene]) {
        guard let item = player?.currentItem else { return }
        zoomCompositionTask?.cancel()
        guard !scenes.isEmpty else {
            item.videoComposition = nil
            zoomCompositionTask = nil
            return
        }
        zoomCompositionTask = Task { @MainActor in
            do {
                let composition = try await ZoomVideoComposition.preview(
                    asset: item.asset,
                    scenes: scenes
                )
                try Task.checkCancellation()
                guard item === player?.currentItem else { return }
                item.videoComposition = composition
            } catch is CancellationError {
                return
            } catch {
                logger.error("Could not build zoom preview: \(error.localizedDescription)")
            }
        }
    }

    private func seekPlayer(to time: Double) {
        guard let edit else { return }
        let boundedTime = min(max(0, time), edit.sourceDuration)
        let playableTime =
            edit.playableSourceTime(atOrAfter: boundedTime)
            ?? edit.lastKeptTime
            ?? boundedTime
        currentTime = playableTime
        player?.seek(
            to: CMTime(seconds: playableTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func selectZoomScene(id: ZoomScene.ID) {
        guard let scene = edit?.zoomScene(id: id) else { return }
        pausePlayback()
        let midpoint = scene.span.start + scene.span.duration / 2
        currentTime = midpoint
        player?.seek(
            to: CMTime(seconds: midpoint, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func updateZoomFocalPoint(_ point: UnitPoint2D, sceneID: ZoomScene.ID) {
        do {
            try edit?.setZoomFocalPoint(point, for: sceneID)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func togglePlayback() {
        guard let player, let edit else { return }
        switch playbackIntent {
        case .playing:
            pausePlayback()
        case .paused:
            if editedCurrentTime >= edit.editedDuration - 0.01,
                let firstKeptTime = edit.sourceTime(forEditedTime: 0)
            {
                seekPlayer(to: firstKeptTime)
            }
            playbackIntent = .playing
            player.play()
        }
    }

    private func pausePlayback() {
        player?.pause()
        playbackIntent = .paused
    }

    private func skipEditedSeconds(_ seconds: Double) {
        guard
            let edit,
            let sourceTime = PostRecordingTimelineMath.sourceTimeBySkipping(
                fromSourceTime: currentTime,
                seconds: seconds,
                edit: edit
            )
        else { return }
        seekPlayer(to: sourceTime)
    }

    private func startVideoExport(quality: VideoExportQuality, suffix: String) {
        guard !isExporting else { return }
        pausePlayback()
        isExporting = true
        exportError = nil
        exportTask = Task { @MainActor in
            await performVideoExport(quality: quality, suffix: suffix)
            isExporting = false
            exportTask = nil
        }
    }

    private func startGIFExport() {
        guard !isExporting else { return }
        pausePlayback()
        isExporting = true
        exportError = nil
        exportTask = Task { @MainActor in
            await performGIFExport()
            isExporting = false
            exportTask = nil
        }
    }

    private func performVideoExport(quality: VideoExportQuality, suffix: String) async {
        guard let outputURL = await selectExportURL(suffix: suffix) else {
            return
        }
        guard let edit else { return }

        do {
            let warning = try await exportVideo(to: outputURL, quality: quality, edit: edit)
            try Task.checkCancellation()
            if let warning {
                exportError = warning.localizedDescription
            }
            let revealed = NSWorkspace.shared.selectFile(outputURL.path(), inFileViewerRootedAtPath: "")
            if !revealed {
                let revealError = "Video saved, but Finder could not reveal it."
                exportError = exportError.map { "\($0)\n\(revealError)" } ?? revealError
            }
        } catch is CancellationError {
            return
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func performGIFExport() async {
        guard let outputURL = await selectExportURL(suffix: "gif", contentType: .gif) else {
            return
        }
        guard let edit else { return }

        do {
            let warning = try await exportGIF(to: outputURL, edit: edit)
            try Task.checkCancellation()
            if let warning {
                exportError = warning.localizedDescription
            }
            let revealed = NSWorkspace.shared.selectFile(outputURL.path(), inFileViewerRootedAtPath: "")
            if !revealed {
                let revealError = "GIF saved, but Finder could not reveal it."
                exportError = exportError.map { "\($0)\n\(revealError)" } ?? revealError
            }
        } catch is CancellationError {
            return
        } catch {
            exportError = "GIF export failed: \(error.localizedDescription)"
        }
    }

    private func exportGIF(to outputURL: URL, edit: TimelineEdit) async throws -> FileReplacementWarning? {
        let tempURL = ExportFileNaming.temporaryURL(for: outputURL)
        defer {
            removeTemporaryExport(at: tempURL, kind: "GIF")
        }

        try await writeGIF(to: tempURL, edit: edit)
        try Task.checkCancellation()
        return try FileReplacement.commit(tempURL: tempURL, to: outputURL)
    }

    private func writeGIF(to outputURL: URL, edit: TimelineEdit) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: GIFExport.maxWidth, height: GIFExport.maxWidth)

        let sampling = GIFExport.frames(edit: edit)
        let imageContext = CIContext(options: [.cacheIntermediates: false])

        guard
            let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.gif.identifier as CFString,
                sampling.times.count,
                nil
            )
        else {
            throw ExportError.gifDestinationUnavailable
        }

        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)

        let frameProperties =
            [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: sampling.delay]
            ] as CFDictionary

        for seconds in sampling.times {
            try Task.checkCancellation()
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let frame = try await generator.image(at: time)
            try Task.checkCancellation()
            let rendered = ZoomImageRenderer.render(
                CIImage(cgImage: frame.image),
                sourceTime: seconds,
                scenes: edit.zoomScenes
            )
            guard let renderedFrame = imageContext.createCGImage(rendered, from: rendered.extent) else {
                throw ExportError.gifFrameRenderFailed
            }
            CGImageDestinationAddImage(destination, renderedFrame, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.gifWriteFailed
        }
    }

    private func selectExportURL(suffix: String, contentType: UTType = .mpeg4Movie) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        let originalName = videoURL.deletingPathExtension().lastPathComponent
        let fileExtension = contentType == .gif ? "gif" : "mp4"
        panel.nameFieldStringValue = "\(originalName)-\(suffix).\(fileExtension)"
        panel.directoryURL = videoURL.deletingLastPathComponent()

        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: keyWindow)
        } else {
            response = panel.runModal()
        }

        guard response == .OK else { return nil }
        return panel.url
    }

    private func exportVideo(
        to outputURL: URL,
        quality: VideoExportQuality,
        edit: TimelineEdit
    ) async throws -> FileReplacementWarning? {
        let tempURL = ExportFileNaming.temporaryURL(for: outputURL)
        defer {
            removeTemporaryExport(at: tempURL, kind: "video")
        }

        try await VideoEditExporter.export(
            sourceURL: videoURL,
            outputURL: tempURL,
            quality: quality,
            edit: edit
        )
        try Task.checkCancellation()
        return try FileReplacement.commit(tempURL: tempURL, to: outputURL)
    }

    private func removeTemporaryExport(at url: URL, kind: String) {
        guard FileManager.default.fileExists(atPath: url.path()) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error(
                "Failed to remove temporary \(kind, privacy: .public) export at \(url.path(), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

enum ExportError: LocalizedError {
    case gifDestinationUnavailable
    case gifFrameRenderFailed
    case gifWriteFailed

    var errorDescription: String? {
        switch self {
        case .gifDestinationUnavailable:
            return "Could not create the GIF file."
        case .gifFrameRenderFailed:
            return "A GIF frame could not be rendered."
        case .gifWriteFailed:
            return "The GIF could not be written."
        }
    }
}

struct PlaybackTransport: View {
    let intent: PlaybackIntent
    let currentTime: Double
    let duration: Double
    let isEnabled: Bool
    let onTogglePlayback: () -> Void
    let onSkip: (Double) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                onSkip(-5)
            } label: {
                Label(PostRecordingText.backFiveSeconds, systemImage: "gobackward.5")
                    .labelStyle(.iconOnly)
            }
            .help(PostRecordingText.backFiveSeconds)
            .accessibilityLabel(PostRecordingText.backFiveSeconds)

            Button(action: onTogglePlayback) {
                Label(
                    intent == .playing ? PostRecordingText.pause : PostRecordingText.play,
                    systemImage: intent == .playing ? "pause.fill" : "play.fill"
                )
                .labelStyle(.iconOnly)
                .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(intent == .playing ? PostRecordingText.pause : PostRecordingText.play)
            .accessibilityLabel(intent == .playing ? PostRecordingText.pause : PostRecordingText.play)

            Button {
                onSkip(5)
            } label: {
                Label(PostRecordingText.forwardFiveSeconds, systemImage: "goforward.5")
                    .labelStyle(.iconOnly)
            }
            .help(PostRecordingText.forwardFiveSeconds)
            .accessibilityLabel(PostRecordingText.forwardFiveSeconds)

            Spacer()

            Text(
                "\(PostRecordingTimelineMath.formattedTime(currentTime)) / \(PostRecordingTimelineMath.formattedTime(duration))"
            )
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 150, alignment: .trailing)
            .accessibilityLabel(PostRecordingText.editedPlaybackTime)
            .accessibilityValue(
                "\(PostRecordingTimelineMath.formattedTime(currentTime)) of \(PostRecordingTimelineMath.formattedTime(duration))"
            )
        }
        .disabled(!isEnabled)
    }
}
