import AppKit
import ScreenCaptureKit
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "ThumbnailCapture")

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

// Deliberately not actor-isolated: thumbnail captures are fired from
// concurrent tasks and SCScreenshotManager is safe to call off the main
// thread.
class ThumbnailCapture {
    /// `maxSize` is in points; `scale` is the backing scale of the screen
    /// the thumbnail is shown on, so it stays sharp on Retina displays.
    static func captureDisplay(
        _ display: SCDisplay,
        excludingApplications: [SCRunningApplication],
        maxSize: CGSize = CGSize(width: 320, height: 180),
        scale: CGFloat
    ) async -> NSImage? {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludingApplications,
            exceptingWindows: []
        )
        let sourceSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        return await capture(filter: filter, sourceSize: sourceSize, maxSize: maxSize, scale: scale)
    }

    static func captureWindow(
        _ window: SCWindow,
        maxSize: CGSize = CGSize(width: 320, height: 180),
        scale: CGFloat
    ) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let sourceSize = CGSize(width: window.frame.width, height: window.frame.height)
        return await capture(filter: filter, sourceSize: sourceSize, maxSize: maxSize, scale: scale)
    }

    private static func capture(
        filter: SCContentFilter,
        sourceSize: CGSize,
        maxSize: CGSize,
        scale: CGFloat
    ) async -> NSImage? {
        do {
            let config = SCStreamConfiguration()

            guard let targetSize = ThumbnailSizing.targetSize(sourceSize: sourceSize, maxSize: maxSize) else {
                logger.warning(
                    "Cannot capture thumbnail for zero-size source: \(sourceSize.width)x\(sourceSize.height)")
                return nil
            }

            config.width = Int((targetSize.width * scale).rounded())
            config.height = Int((targetSize.height * scale).rounded())
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: image, size: targetSize)
        } catch {
            logger.debug("Thumbnail capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}
