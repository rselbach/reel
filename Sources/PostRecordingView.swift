import AppKit
import AVKit
import SwiftUI

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
        guard duration > 0 else { return 0 }
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
        return min(max(0, newStart), trimEnd - TrimConstants.minimumDuration)
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
        return max(min(duration, newEnd), trimStart + TrimConstants.minimumDuration)
    }

    static func seekTime(locationX: CGFloat, handleWidth: CGFloat, usableWidth: CGFloat, duration: Double) -> Double {
        guard usableWidth > 0 else { return 0 }
        let newTime = (locationX - handleWidth) / usableWidth * duration
        return min(max(0, newTime), duration)
    }

    static func formattedTime(_ seconds: Double) -> String {
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
    static let delete = "Delete"
    static let saveTrimmed = "Save Trimmed..."
    static let keyframeNote = "Trimming is lossless; the start point snaps to the nearest keyframe."
    static let done = "Done"
    static let deleteConfirmationTitle = "Delete recording?"
    static let deleteConfirmationMessage = "This will permanently remove the file from disk."
}

enum PostRecordingLogic {
    static func hasTrimChanges(duration: Double, trimStart: Double, trimEnd: Double) -> Bool {
        duration > 0 && (trimStart > TrimConstants.threshold || trimEnd < duration - TrimConstants.threshold)
    }
}

struct PostRecordingView: View {
    let videoURL: URL
    let onDismiss: () -> Void
    let onRevealInFinder: () -> Void
    let onDelete: () -> Void

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var isCleanedUp = false
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var currentTime: Double = 0
    @State private var isExporting = false
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
                .help(PostRecordingText.dragHint)

                Button(justCopied ? PostRecordingText.copied : PostRecordingText.copy) {
                    copyToPasteboard()
                }

                Spacer()
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button(PostRecordingText.revealInFinder) {
                    onRevealInFinder()
                }

                Button(PostRecordingText.delete, role: .destructive) {
                    showDeleteConfirmation = true
                }
                .foregroundColor(.red)

                Spacer()

                if hasTrimChanges {
                    Button(PostRecordingText.saveTrimmed) {
                        Task { await exportTrimmedVideo() }
                    }
                    .disabled(isExporting)
                }

                if isExporting {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Button(PostRecordingText.done) {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
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
            cleanupPlayer()
        }
    }

    private var hasTrimChanges: Bool {
        PostRecordingLogic.hasTrimChanges(duration: duration, trimStart: trimStart, trimEnd: trimEnd)
    }

    /// Puts the recording file on the pasteboard so it can be pasted into
    /// Slack, Mail, Finder, etc.
    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([videoURL as NSURL])
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
                currentTime = CMTimeGetSeconds(time)
            }
        }
    }

    private func exportTrimmedVideo() async {
        guard !isExporting else { return }
        isExporting = true
        exportError = nil

        guard let outputURL = await selectExportURL() else {
            isExporting = false
            return
        }

        do {
            try await trimVideo(to: outputURL)
            let revealed = NSWorkspace.shared.selectFile(outputURL.path(), inFileViewerRootedAtPath: "")
            if !revealed {
                exportError = "Trimmed video saved, but Finder could not reveal it."
            }
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }

        isExporting = false
    }

    private func selectExportURL() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let originalName = videoURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(originalName)-trimmed.mp4"
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

    private func trimVideo(to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let tempURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).mp4")
        defer {
            if FileManager.default.fileExists(atPath: tempURL.path()) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        // Passthrough re-muxes without re-encoding: lossless and near-instant for
        // a pure trim, whereas HighestQuality would re-encode the whole video.
        let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        guard let session else {
            throw ExportError.sessionCreationFailed
        }
        session.timeRange = timeRange
        try await session.export(to: tempURL, as: .mp4)
        try FileReplacement.commit(tempURL: tempURL, to: outputURL)
    }
}

enum ExportError: LocalizedError {
    case sessionCreationFailed

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed: return "Could not create export session"
        }
    }
}

enum FileReplacement {
    static func commit(
        tempURL: URL,
        to outputURL: URL,
        fileManager: FileManager = .default
    ) throws {
        if tempURL == outputURL {
            return
        }

        guard fileManager.fileExists(atPath: outputURL.path()) else {
            try fileManager.moveItem(at: tempURL, to: outputURL)
            return
        }

        let backupURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).reel-backup-\(UUID().uuidString)")

        try fileManager.moveItem(at: outputURL, to: backupURL)
        do {
            try fileManager.moveItem(at: tempURL, to: outputURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if !fileManager.fileExists(atPath: outputURL.path()),
               fileManager.fileExists(atPath: backupURL.path()) {
                try? fileManager.moveItem(at: backupURL, to: outputURL)
            }
            throw error
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
                                    onSeek(TrimSliderMath.seekTime(
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
                                    onSeek(TrimSliderMath.seekTime(
                                        locationX: value.location.x,
                                        handleWidth: handleWidth,
                                        usableWidth: usableWidth,
                                        duration: duration
                                    ))
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
