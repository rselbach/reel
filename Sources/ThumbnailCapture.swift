import AppKit
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "ThumbnailCapture")

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

            let scale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height)
            config.width = max(1, Int(sourceSize.width * scale))
            config.height = max(1, Int(sourceSize.height * scale))
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
