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

    var body: some View {
        VStack(spacing: 16) {
            if let player {
                VideoPlayerView(player: player)
                    .frame(minWidth: 640, minHeight: 360)
            } else {
                ProgressView("Loading...")
                    .frame(minWidth: 640, minHeight: 360)
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

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            player = AVPlayer(url: videoURL)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
