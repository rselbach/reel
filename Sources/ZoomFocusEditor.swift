import AVFoundation
import SwiftUI
import os

private let zoomFocusLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel",
    category: "ZoomFocusEditor"
)

struct ZoomFocusEditor: View {
    let videoURL: URL
    let sourceTime: Double
    let focalPoint: UnitPoint2D
    let onChange: (UnitPoint2D) -> Void

    @State private var frame: CGImage?
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { geometry in
            if let frame {
                let sourceSize = CGSize(width: frame.width, height: frame.height)
                let contentRect = aspectFitRect(sourceSize: sourceSize, in: geometry.size)

                ZStack(alignment: .topLeading) {
                    Color.black

                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: contentRect.width, height: contentRect.height)
                        .position(x: contentRect.midX, y: contentRect.midY)

                    if let layout = ZoomLayout.resolve(
                        sourceSize: sourceSize,
                        focalPoint: focalPoint
                    ) {
                        cropOverlay(
                            layout: layout,
                            sourceSize: sourceSize,
                            contentRect: contentRect
                        )
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: contentRect.width, height: contentRect.height)
                        .position(x: contentRect.midX, y: contentRect.midY)
                        .gesture(focalPointGesture(size: contentRect.size))
                }
            } else if loadFailed {
                ContentUnavailableView(
                    "Could Not Load Zoom Frame",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Select the zoom scene again to retry.")
                )
            } else {
                ProgressView("Loading zoom frame...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .task(id: sourceTime) {
            await loadFrame()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom focal point editor")
        .accessibilityValue(
            "Horizontal \(Int((focalPoint.x * 100).rounded())) percent, vertical \(Int(((1 - focalPoint.y) * 100).rounded())) percent"
        )
        .accessibilityHint("Drag the white circle to choose what stays centered when possible.")
        .accessibilityAction(named: Text("Move focal point left")) {
            adjustFocalPoint(x: -0.05, y: 0)
        }
        .accessibilityAction(named: Text("Move focal point right")) {
            adjustFocalPoint(x: 0.05, y: 0)
        }
        .accessibilityAction(named: Text("Move focal point up")) {
            adjustFocalPoint(x: 0, y: 0.05)
        }
        .accessibilityAction(named: Text("Move focal point down")) {
            adjustFocalPoint(x: 0, y: -0.05)
        }
    }

    private func cropOverlay(
        layout: ZoomLayout,
        sourceSize: CGSize,
        contentRect: CGRect
    ) -> some View {
        let cropRect = displayedRect(
            layout.sourceCropRect,
            sourceSize: sourceSize,
            contentRect: contentRect
        )
        let point = displayedPoint(
            layout.requestedFocalPoint,
            sourceSize: sourceSize,
            contentRect: contentRect
        )

        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(contentRect)
                path.addRoundedRect(in: cropRect, cornerSize: CGSize(width: 8, height: 8))
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 8)
                .stroke(.white, lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)

            Circle()
                .fill(.white)
                .stroke(.black.opacity(0.55), lineWidth: 1)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .position(x: point.x, y: point.y)
                .allowsHitTesting(false)
        }
    }

    private func focalPointGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let x = min(max(0, value.location.x / size.width), 1)
                let y = min(max(0, 1 - value.location.y / size.height), 1)
                guard let point = UnitPoint2D(x: x, y: y) else { return }
                onChange(point)
            }
    }

    private func loadFrame() async {
        frame = nil
        loadFailed = false
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        do {
            let result = try await generator.image(
                at: CMTime(seconds: sourceTime, preferredTimescale: 600)
            )
            try Task.checkCancellation()
            frame = result.image
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
            zoomFocusLogger.error(
                "Could not load source frame at \(sourceTime, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func adjustFocalPoint(x: Double, y: Double) {
        guard
            let point = UnitPoint2D(
                x: min(max(0, focalPoint.x + x), 1),
                y: min(max(0, focalPoint.y + y), 1)
            )
        else { return }
        onChange(point)
    }

    private func aspectFitRect(sourceSize: CGSize, in availableSize: CGSize) -> CGRect {
        let scale = min(
            availableSize.width / sourceSize.width,
            availableSize.height / sourceSize.height
        )
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: (availableSize.width - size.width) / 2,
            y: (availableSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func displayedRect(
        _ sourceRect: CGRect,
        sourceSize: CGSize,
        contentRect: CGRect
    ) -> CGRect {
        let scaleX = contentRect.width / sourceSize.width
        let scaleY = contentRect.height / sourceSize.height
        return CGRect(
            x: contentRect.minX + sourceRect.minX * scaleX,
            y: contentRect.minY + (sourceSize.height - sourceRect.maxY) * scaleY,
            width: sourceRect.width * scaleX,
            height: sourceRect.height * scaleY
        )
    }

    private func displayedPoint(
        _ sourcePoint: CGPoint,
        sourceSize: CGSize,
        contentRect: CGRect
    ) -> CGPoint {
        CGPoint(
            x: contentRect.minX + sourcePoint.x / sourceSize.width * contentRect.width,
            y: contentRect.minY + (1 - sourcePoint.y / sourceSize.height) * contentRect.height
        )
    }
}
