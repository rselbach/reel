import AVFoundation
import CoreImage
import CoreText
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel",
    category: "FrameCompositor"
)

enum CameraCompositeLayout {
    /// Centered square crop applied to camera frames so the composited
    /// overlay matches the preview window, which is a square that aspect-fills
    /// the camera feed.
    static func squareCropRect(width: CGFloat, height: CGFloat) -> CGRect {
        let side = min(width, height)
        return CGRect(
            x: ((width - side) / 2).rounded(.down),
            y: ((height - side) / 2).rounded(.down),
            width: side,
            height: side
        )
    }
}

enum TextOverlayLayout {
    static let maxHeightFraction: CGFloat = 0.35

    static func imageSize(
        suggestedTextSize: CGSize,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        maxImageHeight: CGFloat
    ) -> (imageSize: CGSize, textRect: CGRect) {
        let horizontalPadding = ceil(fontSize * 0.6)
        let verticalPadding = ceil(fontSize * 0.35)
        let availableTextWidth = max(1, maxWidth - horizontalPadding * 2)
        let availableTextHeight = max(fontSize, maxImageHeight - verticalPadding * 2)
        let textWidth = ceil(min(availableTextWidth, max(1, suggestedTextSize.width)))
        let textHeight = ceil(min(availableTextHeight, max(fontSize * 1.25, suggestedTextSize.height)))
        let imageWidth = ceil(textWidth + horizontalPadding * 2)
        let imageHeight = ceil(textHeight + verticalPadding * 2)

        return (
            imageSize: CGSize(width: imageWidth, height: imageHeight),
            textRect: CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: textWidth,
                height: textHeight
            )
        )
    }

    static func yOffset(
        screenHeight: CGFloat,
        overlayHeight: CGFloat,
        margin: CGFloat,
        position: AppSettings.TextOverlayPosition
    ) -> CGFloat {
        let rawOffset: CGFloat
        switch position {
        case .top:
            rawOffset = screenHeight - overlayHeight - margin
        case .center:
            rawOffset = (screenHeight - overlayHeight) / 2
        case .bottom:
            rawOffset = margin
        }

        return min(max(margin, rawOffset), max(margin, screenHeight - overlayHeight - margin))
    }
}

enum WindowFrameLayout {
    /// Padding around the captured window, as a fraction of its longer edge.
    static let paddingFraction: CGFloat = 0.05
    /// Corner radius applied to the captured window, as a fraction of its
    /// longer edge.
    static let cornerRadiusFraction: CGFloat = 0.014
    /// Shadow blur radius, as a fraction of the padding.
    static let shadowBlurFraction: CGFloat = 0.35
    static let minimumPadding: CGFloat = 16

    static func padding(contentSize: CGSize) -> CGFloat {
        let longerEdge = max(contentSize.width, contentSize.height)
        return max(minimumPadding, (longerEdge * paddingFraction).rounded())
    }

    static func cornerRadius(contentSize: CGSize) -> CGFloat {
        let longerEdge = max(contentSize.width, contentSize.height)
        return (longerEdge * cornerRadiusFraction).rounded()
    }

    /// Canvas the padded window is drawn onto. Dimensions are forced even,
    /// which every video encoder requires.
    static func canvasSize(contentSize: CGSize) -> CGSize {
        let padding = padding(contentSize: contentSize)
        let width = Int((contentSize.width + padding * 2).rounded())
        let height = Int((contentSize.height + padding * 2).rounded())
        return CGSize(width: width - width % 2, height: height - height % 2)
    }

    static func contentOrigin(contentSize: CGSize) -> CGPoint {
        let canvas = canvasSize(contentSize: contentSize)
        return CGPoint(
            x: ((canvas.width - contentSize.width) / 2).rounded(),
            y: ((canvas.height - contentSize.height) / 2).rounded()
        )
    }
}

enum FrameFallbackLogic {
    /// A raw screen buffer has the writer's dimensions unless framing added a
    /// larger canvas. In the framed case, it is not a compatible fallback.
    static func canAppendRawFrame(hasWindowFrame: Bool) -> Bool {
        !hasWindowFrame
    }
}

enum CursorHighlightLayout {
    /// Highlight diameter as a fraction of the frame height, so it reads the
    /// same whether the recording is 720p or native Retina.
    static let diameterFraction: CGFloat = 0.055
    static let minimumDiameter: CGFloat = 24

    static func diameter(frameHeight: CGFloat) -> CGFloat {
        max(minimumDiameter, (frameHeight * diameterFraction).rounded())
    }

    /// Maps a global Cocoa cursor location into frame pixel coordinates.
    /// Returns nil when the pointer is outside the captured bounds, where
    /// there is nothing to highlight.
    static func framePoint(
        cursor: CGPoint,
        bounds: CGRect,
        frameWidth: CGFloat,
        frameHeight: CGFloat
    ) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(cursor) else { return nil }

        return CGPoint(
            x: (cursor.x - bounds.minX) / bounds.width * frameWidth,
            y: (cursor.y - bounds.minY) / bounds.height * frameHeight
        )
    }
}

/// Draws Reel's overlays onto captured screen frames.
///
/// Frames arrive on the ScreenCaptureKit output queue rather than the main
/// actor, so this type is deliberately not actor-isolated. Every stored
/// property is either immutable or an NSCache, both of which are safe to
/// touch from that queue.
final class FrameCompositor: @unchecked Sendable {
    /// The camera bubble as it should appear in a single frame.
    struct CameraOverlay {
        let buffer: CVPixelBuffer
        /// Normalized position over the recording bounds, matching the
        /// draggable preview window: 0 is left/bottom, 1 is right/top.
        let x: CGFloat
        let y: CGFloat
        let sizeFraction: CGFloat
        let shape: AppSettings.CameraOverlayShape
        let mirrored: Bool
    }

    /// A pointer position to mark, normalized over the content rect.
    struct ClickHighlight {
        let normalized: CGPoint
        let diameterFraction: CGFloat
    }

    /// Draws the captured window inset on a larger background, with rounded
    /// corners and a drop shadow, the way demo recordings are usually
    /// presented. Absent for display and area recordings.
    struct WindowFrame {
        let canvasSize: CGSize
        let contentOrigin: CGPoint
        let cornerRadius: CGFloat
        let shadowBlur: CGFloat
        let background: BackgroundFill
    }

    /// How the canvas behind a framed window is painted.
    enum BackgroundFill {
        case solid(CIColor)
        /// Interpolated corner to corner, bottom-left to top-right.
        case linearGradient(from: CIColor, to: CIColor)

        /// Stable identity for caching the rendered canvas.
        var cacheKey: String {
            switch self {
            case .solid(let color):
                return "solid-\(color.stringRepresentation)"
            case .linearGradient(let from, let to):
                return "gradient-\(from.stringRepresentation)-\(to.stringRepresentation)"
            }
        }
    }

    private let ciContext: CIContext
    private let circularMaskCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 4
        return cache
    }()
    private let textOverlayCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 8
        return cache
    }()
    private let clickHighlightCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 4
        return cache
    }()
    private let backgroundCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 2
        return cache
    }()

    init(ciContext: CIContext) {
        self.ciContext = ciContext
    }

    /// Drops cached masks and rendered text between recordings, which may use
    /// different overlay sizes and captions.
    func reset() {
        circularMaskCache.removeAllObjects()
        textOverlayCache.removeAllObjects()
        clickHighlightCache.removeAllObjects()
        backgroundCache.removeAllObjects()
    }

    /// Draws the camera bubble and text overlay over a captured screen frame.
    /// Returns nil when there is nothing to draw, so callers write the
    /// untouched screen buffer instead of paying for a needless copy.
    func composite(
        screenBuffer: CVPixelBuffer,
        camera: CameraOverlay?,
        text: TextOverlay?,
        click: ClickHighlight?,
        windowFrame: WindowFrame?,
        bufferPool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        let contentSize = CGSize(
            width: CGFloat(CVPixelBufferGetWidth(screenBuffer)),
            height: CGFloat(CVPixelBufferGetHeight(screenBuffer))
        )

        // Everything positioned over the capture — the camera bubble, click
        // marks, the caption — is laid out against the content rect, so it
        // lands in the same place whether or not the window is framed.
        let contentRect: CGRect
        let outputSize: CGSize
        var composited: CIImage
        var didComposite = false

        if let windowFrame {
            guard let framed = makeFramedContent(screenImage, contentSize: contentSize, frame: windowFrame) else {
                return nil
            }
            composited = framed
            contentRect = CGRect(origin: windowFrame.contentOrigin, size: contentSize)
            outputSize = windowFrame.canvasSize
            didComposite = true
        } else {
            composited = screenImage
            contentRect = CGRect(origin: .zero, size: contentSize)
            outputSize = contentSize
        }

        if let camera {
            guard let cameraOverlay = makeCameraOverlay(camera: camera, contentRect: contentRect) else {
                return nil
            }
            composited = cameraOverlay.composited(over: composited)
            didComposite = true
        }

        if let click, let clickImage = makeClickHighlight(click, contentRect: contentRect) {
            composited = clickImage.composited(over: composited)
            didComposite = true
        }

        if let text,
           let textImage = makeTextOverlayImage(
               text: text.text,
               screenWidth: contentRect.width,
               screenHeight: contentRect.height,
               position: text.position
           ) {
            composited = textImage
                .transformed(by: CGAffineTransform(
                    translationX: contentRect.minX,
                    y: contentRect.minY
                ))
                .composited(over: composited)
            didComposite = true
        }

        guard didComposite else { return nil }

        guard let outputBuffer = makeOutputBuffer(
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bufferPool: bufferPool
        ) else { return nil }

        ciContext.render(composited, to: outputBuffer)
        return outputBuffer
    }

    /// Rounds the captured window's corners, drops a shadow beneath it, and
    /// places it on the background canvas.
    private func makeFramedContent(
        _ screenImage: CIImage,
        contentSize: CGSize,
        frame: WindowFrame
    ) -> CIImage? {
        let canvasRect = CGRect(origin: .zero, size: frame.canvasSize)
        guard let background = backgroundImage(fill: frame.background, canvasRect: canvasRect) else {
            return nil
        }

        guard let roundedMask = roundedRectangle(
            size: contentSize,
            cornerRadius: frame.cornerRadius,
            color: .white
        ) else { return nil }

        let rounded = screenImage
            .transformed(by: CGAffineTransform(
                translationX: -screenImage.extent.origin.x,
                y: -screenImage.extent.origin.y
            ))
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: roundedMask
            ])
            .transformed(by: CGAffineTransform(
                translationX: frame.contentOrigin.x,
                y: frame.contentOrigin.y
            ))

        var canvas = background

        if frame.shadowBlur > 0,
           let shadowShape = roundedRectangle(
               size: contentSize,
               cornerRadius: frame.cornerRadius,
               color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)
           ) {
            // Offset downwards so the shadow reads as cast, not as a halo.
            let shadow = shadowShape
                .transformed(by: CGAffineTransform(
                    translationX: frame.contentOrigin.x,
                    y: frame.contentOrigin.y - frame.shadowBlur * 0.4
                ))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: frame.shadowBlur])
                .cropped(to: canvasRect)
            canvas = shadow.composited(over: canvas)
        }

        return rounded.composited(over: canvas).cropped(to: canvasRect)
    }

    private func backgroundImage(fill: BackgroundFill, canvasRect: CGRect) -> CIImage? {
        let key = "bg-\(Int(canvasRect.width))x\(Int(canvasRect.height))-\(fill.cacheKey)" as NSString
        if let cached = backgroundCache.object(forKey: key) {
            return cached
        }

        let image: CIImage
        switch fill {
        case .solid(let color):
            image = CIImage(color: color).cropped(to: canvasRect)
        case .linearGradient(let from, let to):
            guard let gradient = CIFilter(name: "CILinearGradient") else { return nil }
            gradient.setValue(CIVector(x: canvasRect.minX, y: canvasRect.minY), forKey: "inputPoint0")
            gradient.setValue(CIVector(x: canvasRect.maxX, y: canvasRect.maxY), forKey: "inputPoint1")
            gradient.setValue(from, forKey: "inputColor0")
            gradient.setValue(to, forKey: "inputColor1")
            guard let rendered = gradient.outputImage?.cropped(to: canvasRect) else { return nil }
            image = rendered
        }

        backgroundCache.setObject(image, forKey: key)
        return image
    }

    private func roundedRectangle(size: CGSize, cornerRadius: CGFloat, color: CIColor) -> CIImage? {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else { return nil }
        filter.setValue(CIVector(cgRect: CGRect(origin: .zero, size: size)), forKey: "inputExtent")
        filter.setValue(min(cornerRadius, min(size.width, size.height) / 2), forKey: "inputRadius")
        filter.setValue(color, forKey: "inputColor")
        return filter.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Builds the camera bubble exactly as the draggable preview window shows
    /// it: a square, aspect-fill center crop (mirrored for front cameras)
    /// whose position maps over the full recording bounds with no extra
    /// padding, so what the user drags on screen is what lands in the file.
    private func makeCameraOverlay(
        camera: CameraOverlay,
        contentRect: CGRect
    ) -> CIImage? {
        var cameraImage = CIImage(cvPixelBuffer: camera.buffer)
        let cameraWidth = CGFloat(CVPixelBufferGetWidth(camera.buffer))
        let cameraHeight = CGFloat(CVPixelBufferGetHeight(camera.buffer))
        let overlaySize = CameraOverlayLayout.overlaySize(
            sizeFraction: camera.sizeFraction,
            bounds: contentRect
        ).rounded()
        guard overlaySize > 0, cameraWidth > 0, cameraHeight > 0 else { return nil }

        if camera.mirrored {
            cameraImage = cameraImage
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: cameraWidth, y: 0))
        }

        let cropRect = CameraCompositeLayout.squareCropRect(width: cameraWidth, height: cameraHeight)
        cameraImage = cameraImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        let scale = overlaySize / cropRect.width
        cameraImage = cameraImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if camera.shape == .circle {
            let radius = overlaySize / 2

            let cacheKey = "\(Int(overlaySize))"
            let gradientOutput: CIImage
            if let cached = circularMaskCache.object(forKey: cacheKey as NSString) {
                gradientOutput = cached
            } else {
                guard let radialGradient = CIFilter(name: "CIRadialGradient") else { return nil }
                radialGradient.setValue(CIVector(x: radius, y: radius), forKey: "inputCenter")
                radialGradient.setValue(radius - 1, forKey: "inputRadius0")
                radialGradient.setValue(radius, forKey: "inputRadius1")
                radialGradient.setValue(CIColor.white, forKey: "inputColor0")
                radialGradient.setValue(CIColor.clear, forKey: "inputColor1")

                guard let cachedOutput = radialGradient.outputImage?.cropped(
                    to: CGRect(x: 0, y: 0, width: overlaySize, height: overlaySize)
                ) else { return nil }
                circularMaskCache.setObject(cachedOutput, forKey: cacheKey as NSString)
                gradientOutput = cachedOutput
            }

            cameraImage = cameraImage.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: gradientOutput
            ])
        }

        // Same normalized-position mapping the preview window uses for
        // dragging, over the full frame with no padding.
        let origin = CameraOverlayLayout.originFromNormalized(
            x: camera.x,
            y: camera.y,
            overlaySize: overlaySize,
            bounds: contentRect
        )

        return cameraImage.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// A soft filled disc marking where the pointer was pressed. Drawn only
    /// while a button is down, so it reads as a click rather than as a second
    /// cursor following the pointer around.
    private func makeClickHighlight(_ highlight: ClickHighlight, contentRect: CGRect) -> CIImage? {
        let diameter = CursorHighlightLayout.diameter(frameHeight: contentRect.height)
        guard diameter > 0 else { return nil }

        let point = CGPoint(
            x: contentRect.minX + highlight.normalized.x * contentRect.width,
            y: contentRect.minY + highlight.normalized.y * contentRect.height
        )
        let radius = diameter / 2
        let cacheKey = "click-\(Int(diameter))" as NSString
        let disc: CIImage

        if let cached = clickHighlightCache.object(forKey: cacheKey) {
            disc = cached
        } else {
            guard let gradient = CIFilter(name: "CIRadialGradient") else { return nil }
            gradient.setValue(CIVector(x: radius, y: radius), forKey: "inputCenter")
            gradient.setValue(radius * 0.35, forKey: "inputRadius0")
            gradient.setValue(radius, forKey: "inputRadius1")
            gradient.setValue(CIColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.55), forKey: "inputColor0")
            gradient.setValue(CIColor.clear, forKey: "inputColor1")

            guard let rendered = gradient.outputImage?.cropped(
                to: CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ) else { return nil }
            clickHighlightCache.setObject(rendered, forKey: cacheKey)
            disc = rendered
        }

        return disc.transformed(by: CGAffineTransform(
            translationX: (point.x - radius).rounded(),
            y: (point.y - radius).rounded()
        ))
    }

    private func makeTextOverlayImage(
        text: String,
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        position: AppSettings.TextOverlayPosition
    ) -> CIImage? {
        let fontSize = max(18, min(screenWidth, screenHeight) * 0.045)
        let cacheKey = "\(Int(screenWidth))x\(Int(screenHeight))-\(Int(fontSize.rounded()))-\(text)"
        let baseImage: CIImage

        if let cached = textOverlayCache.object(forKey: cacheKey as NSString) {
            baseImage = cached
        } else {
            guard let rendered = renderTextOverlay(
                text: text,
                fontSize: fontSize,
                maxWidth: screenWidth * 0.85,
                maxImageHeight: screenHeight * TextOverlayLayout.maxHeightFraction
            ) else {
                return nil
            }
            textOverlayCache.setObject(rendered, forKey: cacheKey as NSString)
            baseImage = rendered
        }

        let margin = max(24, min(screenWidth, screenHeight) * 0.04)
        let xOffset = (screenWidth - baseImage.extent.width) / 2
        let yOffset = TextOverlayLayout.yOffset(
            screenHeight: screenHeight,
            overlayHeight: baseImage.extent.height,
            margin: margin,
            position: position
        )

        return baseImage.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
    }

    private func renderTextOverlay(
        text: String,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        maxImageHeight: CGFloat
    ) -> CIImage? {
        var alignment = CTTextAlignment.center
        let paragraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var paragraphSetting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&paragraphSetting, 1)
        }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 0.95),
            kCTParagraphStyleAttributeName: paragraphStyle
        ]

        guard let attributedText = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attributes as CFDictionary
        ) else { return nil }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let horizontalPadding = ceil(fontSize * 0.6)
        let verticalPadding = ceil(fontSize * 0.35)
        let constraint = CGSize(
            width: max(1, maxWidth - horizontalPadding * 2),
            height: max(fontSize, maxImageHeight - verticalPadding * 2)
        )
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraint,
            nil
        )
        let layout = TextOverlayLayout.imageSize(
            suggestedTextSize: suggestedSize,
            fontSize: fontSize,
            maxWidth: maxWidth,
            maxImageHeight: maxImageHeight
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmapContext = CGContext(
            data: nil,
            width: Int(layout.imageSize.width),
            height: Int(layout.imageSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let backgroundRect = CGRect(origin: .zero, size: layout.imageSize)
        let backgroundPath = CGMutablePath()
        backgroundPath.addRoundedRect(
            in: backgroundRect,
            cornerWidth: fontSize * 0.3,
            cornerHeight: fontSize * 0.3
        )
        bitmapContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        bitmapContext.addPath(backgroundPath)
        bitmapContext.fillPath()

        let textPath = CGMutablePath()
        textPath.addRect(layout.textRect)
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            textPath,
            nil
        )
        bitmapContext.textMatrix = .identity
        CTFrameDraw(textFrame, bitmapContext)

        guard let cgImage = bitmapContext.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func makeOutputBuffer(
        width: Int,
        height: Int,
        bufferPool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var outputBuffer: CVPixelBuffer?
        let status: CVReturn
        if let bufferPool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &outputBuffer)
        } else {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &outputBuffer
            )
        }

        if status != kCVReturnSuccess {
            logger.warning("Failed to create output pixel buffer (status: \(status))")
        }
        return outputBuffer
    }
}
