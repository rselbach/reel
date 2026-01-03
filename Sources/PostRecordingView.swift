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
}

struct PostRecordingView: View {
    let videoURL: URL
    let onDismiss: () -> Void
    let onRevealInFinder: () -> Void
    let onDelete: () -> Void

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var currentTime: Double = 0
    @State private var isExporting = false
    @State private var exportError: String?

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
                }
            } else {
                ProgressView("Loading...")
                    .frame(minWidth: 640, minHeight: 360)
            }

            if let error = exportError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack(spacing: 12) {
                Button("Reveal in Finder") {
                    onRevealInFinder()
                }

                Button("Delete", role: .destructive) {
                    onDelete()
                }
                .foregroundColor(.red)

                Spacer()

                if hasTrimChanges {
                    Button("Save Trimmed...") {
                        Task { await exportTrimmedVideo() }
                    }
                    .disabled(isExporting)
                }

                if isExporting {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 700, minHeight: 550)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            if let player, let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
            player?.pause()
            player = nil
        }
    }

    private var hasTrimChanges: Bool {
        duration > 0 && (trimStart > 0.1 || trimEnd < duration - 0.1)
    }

    private func setupPlayer() {
        let asset = AVURLAsset(url: videoURL)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer

        Task {
            if let durationTime = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(durationTime)
                if seconds.isFinite && seconds > 0 {
                    duration = seconds
                    trimEnd = seconds
                }
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        let binding = $currentTime
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                binding.wrappedValue = CMTimeGetSeconds(time)
            }
        }
    }

    private func exportTrimmedVideo() async {
        guard !isExporting else { return }
        isExporting = true
        exportError = nil

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
        guard response == .OK, let outputURL = panel.url else {
            isExporting = false
            return
        }

        do {
            try await trimVideo(to: outputURL)
            NSWorkspace.shared.selectFile(outputURL.path(), inFileViewerRootedAtPath: "")
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }

        isExporting = false
    }

    private func trimVideo(to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)

        if FileManager.default.fileExists(atPath: outputURL.path()) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        guard let session else {
            throw ExportError.sessionCreationFailed
        }
        session.timeRange = timeRange
        try await session.export(to: outputURL, as: .mp4)
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

struct TrimSlider: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var currentTime: Double
    let onSeek: (Double) -> Void

    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false
    @State private var isDraggingPlayhead = false

    private let handleWidth: CGFloat = 12
    private let trackHeight: CGFloat = 50

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
                                    let newTime = (value.location.x - handleWidth) / usableWidth * duration
                                    let clampedTime = min(max(0, newTime), duration)
                                    onSeek(clampedTime)
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
                                    isDraggingStart = true
                                    let newStart = (value.location.x / usableWidth) * duration
                                    trimStart = min(max(0, newStart), trimEnd - 0.5)
                                    onSeek(trimStart)
                                }
                                .onEnded { _ in isDraggingStart = false }
                        )

                    TrimHandle(color: .accentColor)
                        .frame(width: handleWidth, height: trackHeight)
                        .offset(x: endPosition(in: usableWidth) + handleWidth)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isDraggingEnd = true
                                    let newEnd = (value.location.x / usableWidth) * duration
                                    trimEnd = max(min(duration, newEnd), trimStart + 0.5)
                                    onSeek(trimEnd)
                                }
                                .onEnded { _ in isDraggingEnd = false }
                        )

                    Capsule()
                        .fill(Color.white)
                        .frame(width: 8, height: trackHeight + 14)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .offset(x: playheadPosition(in: usableWidth) + handleWidth - 4)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isDraggingPlayhead = true
                                    let newTime = (value.location.x - handleWidth) / usableWidth * duration
                                    let clampedTime = min(max(0, newTime), duration)
                                    onSeek(clampedTime)
                                }
                                .onEnded { _ in isDraggingPlayhead = false }
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
        guard duration > 0 else { return 0 }
        return (trimStart / duration) * width
    }

    private func endPosition(in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return width }
        return (trimEnd / duration) * width
    }

    private func playheadPosition(in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return (currentTime / duration) * width
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", mins, secs, frac)
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
