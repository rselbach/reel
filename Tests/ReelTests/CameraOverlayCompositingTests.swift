import CoreImage
import CoreVideo
import XCTest

@testable import Reel

final class CameraOverlayCompositingTests: XCTestCase {
    private let screenSize = (width: 400, height: 300)

    func testRoundedSquareAndCircleShowTheCameraOnlyInsideTheirShape() throws {
        // A 100 px bubble centered on the frame spans x 150...250 and, in
        // Core Image's bottom-up coordinates, y 100...200.
        for (shape, cornerInset) in [(AppSettings.CameraOverlayShape.roundedSquare, 2), (.circle, 6)] {
            let frame = try composite(shape: shape, pixelsPerPoint: 1)

            XCTAssertTrue(frame.pixel(x: 200, y: 150).isRed, "\(shape) center")
            XCTAssertFalse(frame.pixel(x: 150 + cornerInset, y: 100 + cornerInset).isRed, "\(shape) corner")
            XCTAssertTrue(frame.pixel(x: 200, y: 102).isRed, "\(shape) bottom edge")
        }
    }

    func testCameraShadowFallsBelowTheBubbleAndScalesWithPoints() throws {
        let frame = try composite(shape: .roundedSquare, pixelsPerPoint: 1)
        let below = frame.pixel(x: 200, y: 96)
        let above = frame.pixel(x: 200, y: 204)
        let far = frame.pixel(x: 200, y: 20)

        XCTAssertEqual(far.red, 255)
        XCTAssertLessThan(below.red, far.red)
        XCTAssertLessThan(below.red, above.red, "the shadow drops below the bubble")

        let retina = try composite(shape: .roundedSquare, pixelsPerPoint: 2)
        XCTAssertLessThan(retina.pixel(x: 200, y: 75).red, frame.pixel(x: 200, y: 75).red)
    }

    private func composite(
        shape: AppSettings.CameraOverlayShape,
        pixelsPerPoint: CGFloat
    ) throws -> RenderedFrame {
        let screen = try makeSolidBuffer(width: screenSize.width, height: screenSize.height, bgra: (255, 255, 255))
        let camera = try makeSolidBuffer(width: 64, height: 48, bgra: (0, 0, 255))
        let compositor = FrameCompositor(ciContext: CIContext(options: [.workingColorSpace: NSNull()]))
        let output = try XCTUnwrap(
            compositor.composite(
                screenBuffer: screen,
                camera: FrameCompositor.CameraOverlay(
                    buffer: camera,
                    x: 0.5,
                    y: 0.5,
                    sizeFraction: 0.25,
                    shape: shape,
                    mirrored: false,
                    pixelsPerPoint: pixelsPerPoint
                ),
                text: nil,
                click: nil,
                windowFrame: nil,
                bufferPool: nil
            )
        )
        return RenderedFrame(buffer: output)
    }

    private func makeSolidBuffer(width: Int, height: Int, bgra: (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        XCTAssertEqual(status, kCVReturnSuccess)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * bytesPerRow + column * 4
                base[offset] = bgra.0
                base[offset + 1] = bgra.1
                base[offset + 2] = bgra.2
                base[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}

private struct RenderedFrame {
    struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        var isRed: Bool { red > 200 && green < 60 && blue < 60 }
    }

    let buffer: CVPixelBuffer

    /// Reads a pixel in Core Image's bottom-up coordinates, which is how the
    /// compositor places the bubble.
    func pixel(x: Int, y: Int) -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return Pixel(red: 0, green: 0, blue: 0)
        }
        let offset = (height - 1 - y) * bytesPerRow + x * 4
        return Pixel(red: base[offset + 2], green: base[offset + 1], blue: base[offset])
    }
}
