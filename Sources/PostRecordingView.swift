import AVKit
import AppKit
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
        view.controlsStyle = .floating
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        // Disconnect player during teardown to prevent use-after-free
        nsView.player = nil
    }
}

private enum TrimConstants {
    static let threshold: Double = 0.1
    static let minimumDuration: Double = 0.5
}

enum TrimSliderMath {
    static func startPosition(trimStart: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return (trimStart / duration) * width
    }

    static func endPosition(trimEnd: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return width }
        return (trimEnd / duration) * width
    }

    static func playheadPosition(currentTime: Double, duration: Double, width: CGFloat) -> CGFloat {
        guard currentTime.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return (currentTime / duration) * width
    }

    static func clampedStart(
        origin: Double,
        translationWidth: CGFloat,
        usableWidth: CGFloat,
        duration: Double,
        trimEnd: Double
    ) -> Double {
        guard usableWidth > 0 else { return origin }
        let delta = (translationWidth / usableWidth) * duration
        let newStart = origin + delta
        let minimumDuration = min(TrimConstants.minimumDuration, max(0, duration))
        let latestStart = max(0, trimEnd - minimumDuration)
        return min(max(0, newStart), latestStart)
    }

    static func clampedEnd(
        origin: Double,
        translationWidth: CGFloat,
        usableWidth: CGFloat,
        duration: Double,
        trimStart: Double
    ) -> Double {
        guard usableWidth > 0 else { return origin }
        let delta = (translationWidth / usableWidth) * duration
        let newEnd = origin + delta
        let minimumDuration = min(TrimConstants.minimumDuration, max(0, duration))
        let earliestEnd = min(duration, trimStart + minimumDuration)
        return max(min(duration, newEnd), earliestEnd)
    }

    static func seekTime(locationX: CGFloat, handleWidth: CGFloat, usableWidth: CGFloat, duration: Double) -> Double {
        guard usableWidth > 0, duration.isFinite, duration > 0 else { return 0 }
        let newTime = (locationX - handleWidth) / usableWidth * duration
        return min(max(0, newTime), duration)
    }

    static func translatedSeekTime(
        origin: Double,
        translationWidth: CGFloat,
        usableWidth: CGFloat,
        duration: Double
    ) -> Double {
        guard origin.isFinite, usableWidth > 0, duration.isFinite, duration > 0 else {
            return 0
        }
        let newTime = origin + Double(translationWidth / usableWidth) * duration
        return min(max(0, newTime), duration)
    }

    static func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", mins, secs, frac)
    }
}

enum PostRecordingText {
    static let loading = "Loading..."
    static let revealInFinder = "Reveal in Finder"
    static let copy = "Copy"
    static let copied = "Copied!"
    static let dragHint = "Drag this recording into Slack, Mail, or Finder"
    static let delete = "Move to Trash"
    static let saveTrimmed = "Save Trimmed..."
    static let exportSmaller = "Smaller Copy..."
    static let exportGIF = "GIF..."
    static let exportGIFHelp = "Silent, looping, capped in size and frame count for README and issue embeds."
    static let exportSmallerHelp = "Re-encodes at 720p for sharing in chat, issues, and pull requests."
    static let keyframeNote = "Trimming is lossless; the start point snaps to the nearest keyframe."
    static let done = "Done"
    static let recordAgain = "Record Again"
    static let changeTarget = "Change Target..."
    static let deleteConfirmationTitle = "Move recording to Trash?"
    static let deleteConfirmationMessage = "You can recover it from the Trash."
}

enum GIFExport {
    /// GIF has no interframe compression worth the name, so both the frame
    /// rate and the pixel width stay modest.
    static let frameRate: Double = 12
    static let maxWidth: CGFloat = 800
    /// Roughly 25 seconds at the target frame rate. Longer ranges are sampled
    /// more sparsely rather than cut short, so the whole range is represented.
    static let maxFrames = 300

    /// Sample times across a trim range, plus the per-frame delay that plays
    /// them back at real speed.
    static func frames(start: Double, end: Double) -> (times: [Double], delay: Double) {
        let duration = max(0, end - start)
        guard duration > 0 else { return ([start], 1 / frameRate) }

        let ideal = Int((duration * frameRate).rounded())
        let count = min(maxFrames, max(1, ideal))
        let spacing = duration / Double(count)

        return ((0..<count).map { start + spacing * Double($0) }, spacing)
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
    static func hasTrimChanges(duration: Double, trimStart: Double, trimEnd: Double) -> Bool {
        duration > 0 && (trimStart > TrimConstants.threshold || trimEnd < duration - TrimConstants.threshold)
    }

    static func canExport(
        duration: Double,
        trimStart: Double,
        trimEnd: Double,
        isExporting: Bool
    ) -> Bool {
        duration.isFinite && trimStart.isFinite && trimEnd.isFinite && duration > 0 && trimStart >= 0
            && trimEnd > trimStart && trimEnd <= duration && !isExporting
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
    @State private var timeObserver: Any?
    @State private var isCleanedUp = false
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var currentTime: Double = 0
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var showDeleteConfirmation = false
    @State private var exportError: String?
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 16) {
            if let player {
                VideoPlayerView(player: player)
                    .frame(minWidth: 640, minHeight: 360)

                if duration > 0 {
                    TrimSlider(
                        duration: duration,
                        trimStart: $trimStart,
                        trimEnd: $trimEnd,
                        currentTime: $currentTime,
                        onSeek: { time in
                            player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
                        }
                    )
                    .padding(.horizontal)
                    .disabled(isExporting)

                    if hasTrimChanges {
                        Text(PostRecordingText.keyframeNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                ProgressView(PostRecordingText.loading)
                    .frame(minWidth: 640, minHeight: 360)
            }

            if let error = exportError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack(spacing: 12) {
                // Draggable file chip: the whole point of these recordings is
                // sharing them, so make the file itself grabbable.
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
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button(PostRecordingText.revealInFinder) {
                    onRevealInFinder()
                }
                .disabled(isExporting)

                Button(PostRecordingText.delete, role: .destructive) {
                    showDeleteConfirmation = true
                }
                .foregroundColor(.red)
                .disabled(isExporting)

                Spacer()

                // The next thing after watching a take back is almost always
                // another take of the same thing.
                Button(PostRecordingText.recordAgain) {
                    onRecordAgain()
                }
                .disabled(isExporting)

                Button(PostRecordingText.changeTarget) {
                    onChangeTarget()
                }
                .disabled(isExporting)

                if hasTrimChanges {
                    Button(PostRecordingText.saveTrimmed) {
                        startVideoExport(
                            preset: AVAssetExportPresetPassthrough,
                            suffix: "trimmed"
                        )
                    }
                    .disabled(!canExport)
                }

                Button(PostRecordingText.exportSmaller) {
                    startVideoExport(
                        preset: AVAssetExportPreset1280x720,
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
        .frame(minWidth: 700, minHeight: 550)
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
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            isExporting = false
            cleanupPlayer()
        }
    }

    private var hasTrimChanges: Bool {
        PostRecordingLogic.hasTrimChanges(duration: duration, trimStart: trimStart, trimEnd: trimEnd)
    }

    private var canExport: Bool {
        PostRecordingLogic.canExport(
            duration: duration,
            trimStart: trimStart,
            trimEnd: trimEnd,
            isExporting: isExporting
        )
    }

    /// Puts the recording file on the pasteboard so it can be pasted into
    /// Slack, Mail, Finder, etc.
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

    /// Safely tears down the player and time observer.
    /// Must be called before the view is deallocated to prevent use-after-free crashes.
    private func cleanupPlayer() {
        // Mark as cleaned up first to prevent time observer callback from updating state
        isCleanedUp = true

        // Pause first to stop generating new callbacks
        player?.pause()

        // Remove time observer while player is still valid
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
    }

    private func setupPlayer() {
        let asset = AVURLAsset(url: videoURL)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer

        Task { @MainActor [self] in
            do {
                let durationTime = try await asset.load(.duration)
                guard !isCleanedUp else { return }
                let seconds = CMTimeGetSeconds(durationTime)
                if seconds.isFinite && seconds > 0 {
                    duration = seconds
                    trimEnd = seconds
                }
            } catch {
                guard !isCleanedUp else { return }
                exportError = "Unable to load recording duration: \(error.localizedDescription)"
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak newPlayer] time in
            // Bail if player was deallocated (view is being torn down)
            guard newPlayer != nil else { return }
            Task { @MainActor [self] in
                guard !isCleanedUp else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    currentTime = seconds
                }
            }
        }
    }

    private func startVideoExport(preset: String, suffix: String) {
        guard !isExporting else { return }
        isExporting = true
        exportError = nil
        exportTask = Task { @MainActor in
            await performVideoExport(preset: preset, suffix: suffix)
            isExporting = false
            exportTask = nil
        }
    }

    private func startGIFExport() {
        guard !isExporting else { return }
        isExporting = true
        exportError = nil
        exportTask = Task { @MainActor in
            await performGIFExport()
            isExporting = false
            exportTask = nil
        }
    }

    /// Writes a copy of the current trim range using the given export preset:
    /// passthrough for a lossless trim, a sized preset for a smaller file.
    private func performVideoExport(preset: String, suffix: String) async {
        guard let outputURL = await selectExportURL(suffix: suffix) else {
            return
        }

        do {
            let warning = try await exportVideo(to: outputURL, preset: preset)
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

        do {
            let warning = try await exportGIF(to: outputURL)
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

    private func exportGIF(to outputURL: URL) async throws -> FileReplacementWarning? {
        let tempURL = ExportFileNaming.temporaryURL(for: outputURL)
        defer {
            removeTemporaryExport(at: tempURL, kind: "GIF")
        }

        try await writeGIF(to: tempURL)
        try Task.checkCancellation()
        return try FileReplacement.commit(tempURL: tempURL, to: outputURL)
    }

    private func writeGIF(to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Scales to fit while preserving aspect ratio.
        generator.maximumSize = CGSize(width: GIFExport.maxWidth, height: GIFExport.maxWidth)

        let sampling = GIFExport.frames(start: trimStart, end: trimEnd)

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
            CGImageDestinationAddImage(destination, frame.image, frameProperties)
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

    private func exportVideo(to outputURL: URL, preset: String) async throws -> FileReplacementWarning? {
        let asset = AVURLAsset(url: videoURL)
        let tempURL = ExportFileNaming.temporaryURL(for: outputURL)
        defer {
            removeTemporaryExport(at: tempURL, kind: "video")
        }

        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        // Passthrough re-muxes without re-encoding: lossless and near-instant
        // for a pure trim. A sized preset re-encodes, which is the point when
        // the goal is a smaller file.
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExportError.presetUnavailable(preset)
        }
        session.timeRange = timeRange
        try await session.export(to: tempURL, as: .mp4)
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
    case presetUnavailable(String)
    case gifDestinationUnavailable
    case gifWriteFailed

    var errorDescription: String? {
        switch self {
        case .presetUnavailable(let preset):
            return "This recording cannot be exported with the \(preset) preset."
        case .gifDestinationUnavailable:
            return "Could not create the GIF file."
        case .gifWriteFailed:
            return "The GIF could not be written."
        }
    }
}

struct TrimSlider: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var currentTime: Double
    let onSeek: (Double) -> Void

    private let handleWidth: CGFloat = 12
    private let trackHeight: CGFloat = 50
    @State private var startHandleDragOrigin: Double?
    @State private var endHandleDragOrigin: Double?
    @State private var playheadDragOrigin: Double?

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let usableWidth = totalWidth - handleWidth * 2

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: trackHeight)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    onSeek(
                                        TrimSliderMath.seekTime(
                                            locationX: value.location.x,
                                            handleWidth: handleWidth,
                                            usableWidth: usableWidth,
                                            duration: duration
                                        ))
                                }
                        )

                    Rectangle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: startPosition(in: usableWidth), height: trackHeight)
                        .allowsHitTesting(false)

                    Rectangle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: totalWidth - endPosition(in: usableWidth) - handleWidth, height: trackHeight)
                        .offset(x: endPosition(in: usableWidth) + handleWidth)
                        .allowsHitTesting(false)

                    Rectangle()
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(
                            width: endPosition(in: usableWidth) - startPosition(in: usableWidth),
                            height: trackHeight
                        )
                        .offset(x: startPosition(in: usableWidth) + handleWidth)
                        .allowsHitTesting(false)

                    TrimHandle(color: .accentColor)
                        .frame(width: handleWidth, height: trackHeight)
                        .offset(x: startPosition(in: usableWidth))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    guard usableWidth > 0 else { return }
                                    if startHandleDragOrigin == nil {
                                        startHandleDragOrigin = trimStart
                                    }
                                    let origin = startHandleDragOrigin ?? trimStart
                                    trimStart = TrimSliderMath.clampedStart(
                                        origin: origin,
                                        translationWidth: value.translation.width,
                                        usableWidth: usableWidth,
                                        duration: duration,
                                        trimEnd: trimEnd
                                    )
                                    onSeek(trimStart)
                                }
                                .onEnded { _ in
                                    startHandleDragOrigin = nil
                                }
                        )

                    TrimHandle(color: .accentColor)
                        .frame(width: handleWidth, height: trackHeight)
                        .offset(x: endPosition(in: usableWidth) + handleWidth)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    guard usableWidth > 0 else { return }
                                    if endHandleDragOrigin == nil {
                                        endHandleDragOrigin = trimEnd
                                    }
                                    let origin = endHandleDragOrigin ?? trimEnd
                                    trimEnd = TrimSliderMath.clampedEnd(
                                        origin: origin,
                                        translationWidth: value.translation.width,
                                        usableWidth: usableWidth,
                                        duration: duration,
                                        trimStart: trimStart
                                    )
                                    onSeek(trimEnd)
                                }
                                .onEnded { _ in
                                    endHandleDragOrigin = nil
                                }
                        )

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 8, height: trackHeight + 14)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .offset(x: playheadPosition(in: usableWidth) + handleWidth - 4)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if playheadDragOrigin == nil {
                                        playheadDragOrigin = currentTime
                                    }
                                    let time = TrimSliderMath.translatedSeekTime(
                                        origin: playheadDragOrigin ?? currentTime,
                                        translationWidth: value.translation.width,
                                        usableWidth: usableWidth,
                                        duration: duration
                                    )
                                    currentTime = time
                                    onSeek(time)
                                }
                                .onEnded { _ in
                                    playheadDragOrigin = nil
                                }
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: trackHeight)

            HStack {
                Text(formatTime(trimStart))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTime(currentTime))
                    .font(.caption.monospacedDigit())
                Spacer()
                Text(formatTime(trimEnd))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private func startPosition(in width: CGFloat) -> CGFloat {
        TrimSliderMath.startPosition(trimStart: trimStart, duration: duration, width: width)
    }

    private func endPosition(in width: CGFloat) -> CGFloat {
        TrimSliderMath.endPosition(trimEnd: trimEnd, duration: duration, width: width)
    }

    private func playheadPosition(in width: CGFloat) -> CGFloat {
        TrimSliderMath.playheadPosition(currentTime: currentTime, duration: duration, width: width)
    }

    private func formatTime(_ seconds: Double) -> String {
        TrimSliderMath.formattedTime(seconds)
    }
}

struct TrimHandle: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .overlay(
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 4, height: 2)
                    }
                }
            )
    }
}
