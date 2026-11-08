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

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
    }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: ()) {
        nsView.player = nil
    }
}

/// Shows the player's video and nothing else. AVPlayerView would add Live
/// Text, which makes text in a paused frame selectable, and its own Space,
/// J, K, L, and arrow keys, which play straight through deleted clips.
final class PlayerLayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func makeBackingLayer() -> CALayer {
        playerLayer
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
    static let copyHelp = "Copy the recording, with your edits, to paste into Slack, Mail, or Finder"
    static let share = "Share"
    static let shareHelp = "Share the recording, with your edits"
    static let more = "More"
    static let delete = "Move to Trash..."
    static let confirmDelete = "Move to Trash"
    static let timeline = "Timeline"
    static let timelineHelp = "Drag either end to trim. To remove a middle part, split around it and delete it."
    static let split = "Split"
    static let splitHelp = "Split the clip at the playhead (⌘B)"
    static let trimStart = "Trim start"
    static let trimEnd = "Trim end"
    static let trimHandleHelp =
        "Drag to trim, or press I or O to trim to the playhead. Trimmed footage stays on the timeline so you can restore it."
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
    static let zoomSettings = "Zoom Settings..."
    static let editClipFailedTitle = "Could Not Edit Timeline"
    static let splitClipFailedMessage =
        "Move the playhead at least 0.05 seconds from either edge of a clip, then split again."
    static let deleteClipFailedMessage =
        "The edited recording must keep at least 0.5 seconds."
    static let playhead = "Playhead"
    static let playheadHint = "Drag to seek. Split to cut the clip here."
    static let backFiveSeconds = "Back 5 seconds"
    static let forwardFiveSeconds = "Forward 5 seconds"
    static let play = "Play"
    static let pause = "Pause"
    static let playHelp = "Play or pause (Space). J, K, and L play backward, pause, and play forward."
    static let editedPlaybackTime = "Edited playback time"
    static let export = "Export"
    static let exportEdited = "Edited Video..."
    static let exportEditedHelp = "Full size, with your edits"
    static let exportSmaller = "Smaller Copy (720p)..."
    static let exportSmallerHelp = "For chat, issues, and pull requests"
    static let exportGIF = "Animated GIF..."
    static let exportGIFHelp = "Silent and looping, for READMEs and issues"
    static let exporting = "Exporting"
    static let cancelExport = "Cancel"
    static let showInFinder = "Show in Finder"
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

struct ExportedVideo: Equatable {
    let edit: TimelineEdit
    let url: URL
}

enum PostRecordingLogic {
    static func canExport(edit: TimelineEdit?, isExporting: Bool) -> Bool {
        guard let edit else { return false }
        return edit.editedDuration > 0 && !isExporting
    }

    /// The file drag and Copy hand out: the recording itself until the
    /// timeline is edited, then the latest video exported from exactly this
    /// edit. Nil while the edits exist only in the preview, since the
    /// original would not match what the preview shows.
    static func shareURL(original: URL, edit: TimelineEdit?, exportedVideo: ExportedVideo?) -> URL? {
        guard let edit, edit.hasMeaningfulChanges else { return original }
        guard let exportedVideo, exportedVideo.edit == edit else { return nil }
        return exportedVideo.url
    }
}

/// Hands out the file that Copy, Share, and a drag of the title bar's icon
/// share: the recording itself until it is edited, then a video rendered
/// from the edits. The preview fills in the closures.
@MainActor
final class PreviewShareSource {
    /// The file to share if it exists already, without rendering.
    var readyFile: () -> URL? = { nil }
    /// The file to share, rendering the edits first if needed.
    var file: () async throws -> URL = { throw CancellationError() }
    /// What the shared file is called.
    var fileName: () -> String = { "Recording.mp4" }

    func shareableFile() async throws -> URL {
        try await file()
    }
}

/// Shares the preview's file through the system share menu, which asks for
/// it only once a service is chosen, so the edits render only when needed.
struct SharedRecording: Transferable {
    let source: PreviewShareSource

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { recording in
            SentTransferredFile(try await recording.source.shareableFile())
        }
    }
}

/// Lets the Edit menu's Undo and Redo reach a preview's timeline, whose
/// history lives in SwiftUI state. The preview fills in the closures.
@MainActor
final class PreviewUndoCommands {
    var canUndo: () -> Bool = { false }
    var canRedo: () -> Bool = { false }
    var undo: () -> Void = {}
    var redo: () -> Void = {}
}

struct PostRecordingView: View {
    let videoURL: URL
    let undoCommands: PreviewUndoCommands
    let shareSource: PreviewShareSource
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
    @State private var history = TimelineHistory()
    @State private var exportedVideo: ExportedVideo?
    @State private var currentTime: Double = 0
    @State private var playbackIntent: PlaybackIntent = .paused
    /// One frame of the recording, for the arrow keys.
    @State private var frameDuration: Double = 1.0 / 30
    /// While a timeline drag shows frames from footage that may be deleted,
    /// playback must not move the playhead back onto kept footage.
    @State private var isScrubbing = false
    @State private var timelineSelection: TimelineSelection = .none
    @State private var isExporting = false
    /// How far the file being written has got; nil while nothing is written.
    @State private var exportProgress: Double?
    /// The file the last export wrote, until the edit changes.
    @State private var lastExportURL: URL?
    @State private var exportTask: Task<Void, Never>?
    /// Rendering the edits for Copy, Share, or a drag, so later requests for
    /// the same edit wait for it instead of starting another.
    @State private var shareRender: (edit: TimelineEdit, task: Task<URL, Error>)?
    @State private var showDeleteConfirmation = false
    @State private var exportError: String?
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 14) {
            if !isScrubbing, case .zoomScene(let sceneID) = timelineSelection,
                let edit, let scene = edit.zoomScene(id: sceneID)
            {
                ZoomFocusEditor(
                    videoURL: videoURL,
                    sourceTime: min(currentTime, max(0, edit.sourceDuration - frameDuration)),
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
                isEnabled: player != nil && edit != nil && !isExporting,
                onTogglePlayback: togglePlayback,
                onSkip: skipEditedSeconds
            )
            .padding(.horizontal)
            .background {
                playbackShortcuts
            }

            if let loadedEdit = edit {
                PostRecordingTimelineView(
                    videoURL: videoURL,
                    edit: Binding(
                        get: { self.edit ?? loadedEdit },
                        set: { applyEdit($0) }
                    ),
                    currentSourceTime: $currentTime,
                    selection: $timelineSelection,
                    onSeek: seekPlayer,
                    onScrub: scrub,
                    onSelectZoomScene: selectZoomScene
                )
                .padding(.horizontal)
                .disabled(isExporting)
            }

            HStack(spacing: 12) {
                Menu {
                    Button(PostRecordingText.changeTarget, action: onChangeTarget)
                } label: {
                    Text(PostRecordingText.recordAgain)
                } primaryAction: {
                    onRecordAgain()
                }
                .fixedSize()
                .disabled(isExporting)

                // The space stays when there is no status, keeping Done at
                // the trailing edge.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .overlay { statusLine }

                Button(PostRecordingText.done) {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
            // Fixed, so a status message never moves the video or timeline.
            .frame(height: 30)
            .padding(.horizontal)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    copyToPasteboard()
                } label: {
                    Label(
                        justCopied ? PostRecordingText.copied : PostRecordingText.copy,
                        systemImage: justCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .help(PostRecordingText.copyHelp)
                .disabled(isExporting || edit == nil)

                ShareLink(
                    item: SharedRecording(source: shareSource),
                    preview: SharePreview(shareFileName)
                ) {
                    Label(PostRecordingText.share, systemImage: "square.and.arrow.up")
                }
                .help(PostRecordingText.shareHelp)
                .disabled(isExporting || edit == nil)

                exportMenu

                Menu {
                    Button(PostRecordingText.revealInFinder, action: onRevealInFinder)
                    Divider()
                    Button(PostRecordingText.delete, role: .destructive) {
                        showDeleteConfirmation = true
                    }
                } label: {
                    Label(PostRecordingText.more, systemImage: "ellipsis.circle")
                }
                .help(PostRecordingText.more)
                .disabled(isExporting)
            }
        }
        .padding()
        .frame(minWidth: 780, minHeight: 700)
        .alert(PostRecordingText.deleteConfirmationTitle, isPresented: $showDeleteConfirmation) {
            Button(PostRecordingText.confirmDelete, role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PostRecordingText.deleteConfirmationMessage)
        }
        .onAppear {
            setupPlayer()
            connectUndoCommands()
            connectShareSource()
        }
        .onChange(of: edit) { previousEdit, changedEdit in
            lastExportURL = nil
            guard let changedEdit else {
                timelineSelection = .none
                player?.currentItem?.videoComposition = nil
                return
            }
            timelineSelection = timelineSelection.validated(for: changedEdit)
            saveEdit(changedEdit)
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
            shareRender?.task.cancel()
            shareRender = nil
            isExporting = false
            cleanupPlayer()
        }
    }

    private var hasEdits: Bool {
        edit?.hasMeaningfulChanges == true
    }

    private var shareURL: URL? {
        PostRecordingLogic.shareURL(original: videoURL, edit: edit, exportedVideo: exportedVideo)
    }

    /// Export progress, the last error, or the file just saved, one at a
    /// time in the bottom bar.
    @ViewBuilder
    private var statusLine: some View {
        if let exportProgress {
            HStack(spacing: 8) {
                Text("\(PostRecordingText.exporting) \(Int((exportProgress * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ProgressView(value: exportProgress)
                    .frame(width: 120)
                    .accessibilityLabel(PostRecordingText.exporting)
                Button(PostRecordingText.cancelExport) {
                    exportTask?.cancel()
                    shareRender?.task.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        } else if let exportError {
            Text(exportError)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .truncationMode(.middle)
        } else if let lastExportURL {
            exportedNote(for: lastExportURL)
        }
    }

    private var exportMenu: some View {
        Menu(PostRecordingText.export) {
            Button {
                startExport(.video(.source, suffix: "edited"))
            } label: {
                Text(PostRecordingText.exportEdited)
                Text(PostRecordingText.exportEditedHelp)
            }
            .disabled(!hasEdits)

            Button {
                startExport(.video(.p720, suffix: "720p"))
            } label: {
                Text(PostRecordingText.exportSmaller)
                Text(PostRecordingText.exportSmallerHelp)
            }

            Button {
                startExport(.gif)
            } label: {
                Text(PostRecordingText.exportGIF)
                Text(PostRecordingText.exportGIFHelp)
            }
        }
        .fixedSize()
        .help(PostRecordingText.export)
        .disabled(!canExport)
    }

    private func exportedNote(for url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Saved “\(url.lastPathComponent)”")
                .lineLimit(1)
                .truncationMode(.middle)
            Button(PostRecordingText.showInFinder) {
                if !NSWorkspace.shared.selectFile(url.path(percentEncoded: false), inFileViewerRootedAtPath: "") {
                    exportError = "Finder could not show \(url.lastPathComponent)."
                }
            }
            .buttonStyle(.link)
        }
        .font(.caption)
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
        Task { @MainActor in
            do {
                writeToPasteboard(try await fileToShare())
            } catch is CancellationError {
                return
            } catch {
                exportError = "Could not prepare the recording to copy: \(error.localizedDescription)"
            }
        }
    }

    private func writeToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
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

    private var shareFileName: String {
        guard hasEdits else { return videoURL.lastPathComponent }
        return "\(videoURL.deletingPathExtension().lastPathComponent)-edited.mp4"
    }

    private func connectShareSource() {
        shareSource.readyFile = { shareURL }
        shareSource.file = fileToShare
        shareSource.fileName = { shareFileName }
    }

    /// The recording while it is unedited, else a full-size video of the
    /// edits, rendered once into a temporary folder and reused until the
    /// edits change.
    private func fileToShare() async throws -> URL {
        if let shareURL {
            return shareURL
        }
        guard let edit else { throw CancellationError() }
        if let shareRender, shareRender.edit == edit {
            return try await shareRender.task.value
        }
        guard !isExporting else { throw CancellationError() }

        let fileName = shareFileName
        let task = Task { @MainActor () throws -> URL in
            isExporting = true
            exportError = nil
            exportProgress = 0
            defer {
                isExporting = false
                exportProgress = nil
            }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Reel Shares", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(fileName)
            try await VideoEditExporter.export(
                sourceURL: videoURL,
                outputURL: url,
                quality: .source,
                edit: edit,
                onProgress: { exportProgress = $0 }
            )
            try Task.checkCancellation()
            exportedVideo = ExportedVideo(edit: edit, url: url)
            return url
        }
        shareRender = (edit, task)
        defer {
            if shareRender?.edit == edit {
                shareRender = nil
            }
        }
        return try await task.value
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
                if let freshEdit = TimelineEdit(sourceDuration: seconds) {
                    let loadedEdit = SavedTimelineEdit.load(from: videoURL, sourceDuration: seconds) ?? freshEdit
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
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
                let rate = try await track.load(.nominalFrameRate)
                guard !isCleanedUp, rate > 0 else { return }
                frameDuration = 1 / Double(rate)
            } catch {
                logger.warning("Unable to load the frame rate: \(error.localizedDescription)")
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
                guard !isCleanedUp, !isScrubbing else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite, let edit else { return }
                if let rate = newPlayer?.rate, rate < 0 {
                    followReversePlayback(at: seconds, edit: edit)
                    return
                }
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

    /// Playing backward, the player skips deleted clips toward the start and
    /// pauses on the first kept frame.
    private func followReversePlayback(at seconds: Double, edit: TimelineEdit) {
        let first = edit.firstKeptTime ?? 0
        guard seconds > first + 0.01, let playable = edit.playableSourceTime(atOrBefore: seconds) else {
            pausePlayback()
            seekPlayer(to: first)
            return
        }
        currentTime = playable
        guard playable < seconds - 0.001 else { return }
        player?.seek(
            to: CMTime(seconds: playable, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
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
                        // Reverse playback is handled by the periodic observer.
                        player.rate > 0,
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

    private func scrub(to time: Double?) {
        guard let time else {
            isScrubbing = false
            return
        }
        if !isScrubbing {
            pausePlayback()
            isScrubbing = true
        }
        currentTime = time
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
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
        guard var changed = edit else { return }
        do {
            try changed.setZoomFocalPoint(point, for: sceneID)
        } catch {
            exportError = error.localizedDescription
            return
        }
        applyEdit(changed)
    }

    /// Edits are kept with the recording as they are made, so closing the
    /// preview never loses them.
    private func saveEdit(_ edit: TimelineEdit) {
        do {
            try SavedTimelineEdit.save(edit, to: videoURL)
        } catch {
            logger.error("Could not save edits: \(error.localizedDescription, privacy: .public)")
            exportError = "Reel could not save your edits with the recording: \(error.localizedDescription)"
        }
    }

    /// Every change to the edit comes through here so it can be undone.
    private func applyEdit(_ changed: TimelineEdit) {
        guard let edit else { return }
        history.record(from: edit, to: changed)
        self.edit = changed
    }

    private func undoEdit() {
        guard let edit, let previous = history.undo(from: edit) else { return }
        showRestoredEdit(previous)
    }

    private func redoEdit() {
        guard let edit, let next = history.redo(from: edit) else { return }
        showRestoredEdit(next)
    }

    private var canUndo: Bool {
        history.canUndo && !isExporting
    }

    private var canRedo: Bool {
        history.canRedo && !isExporting
    }

    private func connectUndoCommands() {
        undoCommands.canUndo = { canUndo }
        undoCommands.canRedo = { canRedo }
        undoCommands.undo = undoEdit
        undoCommands.redo = redoEdit
    }

    private func showRestoredEdit(_ restored: TimelineEdit) {
        edit = restored
        // Moves the playhead off footage the restored edit deletes.
        seekPlayer(to: currentTime)
    }

    private func togglePlayback() {
        guard let player, let edit else { return }
        if case .zoomScene(let id) = timelineSelection, let scene = edit.zoomScene(id: id) {
            playZoomScene(scene)
            return
        }
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

    /// Playing while a zoom scene is being aimed leaves the focal point
    /// editor and plays from just before the scene, so its zoom shows in
    /// motion.
    private func playZoomScene(_ scene: ZoomScene) {
        timelineSelection = .none
        seekPlayer(to: max(0, scene.span.start - 1))
        playbackIntent = .playing
        player?.play()
    }

    /// L plays forward and J backward, each faster with another press, up to
    /// four times normal speed.
    private func shuttle(forward: Bool) {
        guard let player, let edit else { return }
        if isEditingZoomFocus {
            timelineSelection = .none
        }
        let direction: Float = forward ? 1 : -1
        let speed = playbackIntent == .playing && player.rate * direction > 0 ? min(abs(player.rate) * 2, 4) : 1
        if forward, editedCurrentTime >= edit.editedDuration - 0.01, let first = edit.firstKeptTime {
            seekPlayer(to: first)
        }
        if !forward {
            guard player.currentItem?.canPlayReverse == true, currentTime > (edit.firstKeptTime ?? 0) + 0.01 else {
                return
            }
        }
        playbackIntent = .playing
        player.rate = speed * direction
    }

    private func stepFrames(_ count: Int) {
        pausePlayback()
        if isEditingZoomFocus {
            timelineSelection = .none
        }
        let target = currentTime + Double(count) * frameDuration
        guard count < 0, let edit else {
            seekPlayer(to: target)
            return
        }
        seekPlayer(to: edit.playableSourceTime(atOrBefore: target) ?? edit.firstKeptTime ?? 0)
    }

    private func trimToPlayhead(_ edge: TrimEdge) {
        guard var changed = edit else { return }
        changed.trim(edge, to: currentTime)
        guard changed != edit else { return }
        applyEdit(changed)
        seekPlayer(to: currentTime)
    }

    /// Keys a video editor is expected to have: the arrows step a frame,
    /// J, K, and L shuttle, I and O trim to the playhead, and Home and End
    /// go to either end.
    private var playbackShortcuts: some View {
        let shortcuts: [(KeyboardShortcut, () -> Void)] = [
            (KeyboardShortcut(.leftArrow, modifiers: []), { stepFrames(-1) }),
            (KeyboardShortcut(.rightArrow, modifiers: []), { stepFrames(1) }),
            (KeyboardShortcut("j", modifiers: []), { shuttle(forward: false) }),
            (KeyboardShortcut("k", modifiers: []), { pausePlayback() }),
            (KeyboardShortcut("l", modifiers: []), { shuttle(forward: true) }),
            (KeyboardShortcut("i", modifiers: []), { trimToPlayhead(.start) }),
            (KeyboardShortcut("o", modifiers: []), { trimToPlayhead(.end) }),
            (KeyboardShortcut(.home, modifiers: []), { seekPlayer(to: edit?.firstKeptTime ?? 0) }),
            (KeyboardShortcut(.end, modifiers: []), { seekPlayer(to: edit?.lastKeptTime ?? 0) }),
        ]
        return ZStack {
            ForEach(shortcuts.indices, id: \.self) { index in
                Button("", action: shortcuts[index].1)
                    .keyboardShortcut(shortcuts[index].0)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .disabled(player == nil || edit == nil || isExporting)
    }

    private func pausePlayback() {
        player?.pause()
        playbackIntent = .paused
    }

    private func skipEditedSeconds(_ seconds: Double) {
        if isEditingZoomFocus {
            timelineSelection = .none
        }
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

    private func startExport(_ format: ExportFormat) {
        guard !isExporting, let edit else { return }
        pausePlayback()
        isExporting = true
        exportError = nil
        lastExportURL = nil
        exportTask = Task { @MainActor in
            defer {
                isExporting = false
                exportProgress = nil
                exportTask = nil
            }
            guard let outputURL = await selectExportURL(for: format) else { return }
            exportProgress = 0

            do {
                let warning: FileReplacementWarning?
                switch format {
                case .video(let quality, _):
                    warning = try await exportVideo(to: outputURL, quality: quality, edit: edit)
                    // A smaller copy is not what Copy and Share should hand out.
                    if quality == .source {
                        exportedVideo = ExportedVideo(edit: edit, url: outputURL)
                    }
                case .gif:
                    warning = try await exportGIF(to: outputURL, edit: edit)
                }
                lastExportURL = outputURL
                if let warning {
                    exportError = warning.localizedDescription
                }
            } catch is CancellationError {
                return
            } catch {
                exportError = "Export failed: \(error.localizedDescription)"
            }
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

        for (index, seconds) in sampling.times.enumerated() {
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
            exportProgress = Double(index + 1) / Double(sampling.times.count)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.gifWriteFailed
        }
        try gifData.write(to: outputURL)
    }

    private func selectExportURL(for format: ExportFormat) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let originalName = videoURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(originalName)-\(format.suffix).\(format.fileExtension)"
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
            edit: edit,
            onProgress: { exportProgress = $0 }
        )
        try Task.checkCancellation()
        return try FileReplacement.commit(tempURL: tempURL, to: outputURL)
    }

    private func removeTemporaryExport(at url: URL, kind: String) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error(
                "Failed to remove temporary \(kind, privacy: .public) export at \(url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

private enum ExportFormat {
    case video(VideoExportQuality, suffix: String)
    case gif

    var suffix: String {
        switch self {
        case .video(_, let suffix):
            return suffix
        case .gif:
            return "gif"
        }
    }

    var contentType: UTType {
        switch self {
        case .video:
            return .mpeg4Movie
        case .gif:
            return .gif
        }
    }

    var fileExtension: String {
        switch self {
        case .video:
            return "mp4"
        case .gif:
            return "gif"
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
            .help(PostRecordingText.playHelp)
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
