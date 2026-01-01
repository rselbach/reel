import AppKit
import ScreenCaptureKit

@MainActor
class ThumbnailCapture {
    static func captureDisplay(_ display: SCDisplay, maxSize: CGSize = CGSize(width: 320, height: 180)) async -> NSImage? {
        do {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            
            let scale = min(maxSize.width / CGFloat(display.width), maxSize.height / CGFloat(display.height))
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: image, size: NSSize(width: config.width, height: config.height))
        } catch {
            return nil
        }
    }
    
    static func captureWindow(_ window: SCWindow, maxSize: CGSize = CGSize(width: 320, height: 180)) async -> NSImage? {
        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            
            let scale = min(maxSize.width / window.frame.width, maxSize.height / window.frame.height)
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: image, size: NSSize(width: config.width, height: config.height))
        } catch {
            return nil
        }
    }
}
