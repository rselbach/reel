import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "ThumbnailCapture")

enum ThumbnailSizing {
    static func targetSize(sourceSize: CGSize, maxSize: CGSize) -> CGSize? {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height)
        return CGSize(
            width: max(1, Int(sourceSize.width * scale)),
            height: max(1, Int(sourceSize.height * scale))
        )
    }
}

@MainActor
class ThumbnailCapture {
    static func captureDisplay(_ display: SCDisplay, maxSize: CGSize = CGSize(width: 320, height: 180)) async -> NSImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let sourceSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        return await capture(filter: filter, sourceSize: sourceSize, maxSize: maxSize)
    }

    static func captureWindow(_ window: SCWindow, maxSize: CGSize = CGSize(width: 320, height: 180)) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let sourceSize = CGSize(width: window.frame.width, height: window.frame.height)
        return await capture(filter: filter, sourceSize: sourceSize, maxSize: maxSize)
    }

    private static func capture(
        filter: SCContentFilter,
        sourceSize: CGSize,
        maxSize: CGSize
    ) async -> NSImage? {
        do {
            let config = SCStreamConfiguration()

            guard let targetSize = ThumbnailSizing.targetSize(sourceSize: sourceSize, maxSize: maxSize) else {
                logger.warning("Cannot capture thumbnail for zero-size source: \(sourceSize.width)x\(sourceSize.height)")
                return nil
            }

            config.width = Int(targetSize.width)
            config.height = Int(targetSize.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: image, size: NSSize(width: config.width, height: config.height))
        } catch {
            logger.debug("Thumbnail capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}
