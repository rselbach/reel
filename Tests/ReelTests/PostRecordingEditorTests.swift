import AVFoundation
import CoreGraphics
import ImageIO
import XCTest

@testable import Reel

final class PostRecordingEditorTests: XCTestCase {
    @MainActor
    func testPreviewUndoCommandsResetBreaksRetainCycle() {
        final class Token {}

        let commands = PreviewUndoCommands()
        weak var weakToken: Token?
        do {
            let token = Token()
            weakToken = token
            commands.canUndo = {
                _ = token
                return true
            }
            commands.canRedo = {
                _ = token
                return true
            }
            commands.undo = { _ = token }
            commands.redo = { _ = token }
        }
        XCTAssertNotNil(weakToken)
        XCTAssertTrue(commands.canUndo())
        XCTAssertTrue(commands.canRedo())

        commands.reset()

        XCTAssertNil(weakToken)
        XCTAssertFalse(commands.canUndo())
        XCTAssertFalse(commands.canRedo())
    }

    @MainActor
    func testPreviewShareSourceResetBreaksRetainCycle() async {
        final class Token {}

        let source = PreviewShareSource()
        let sampleURL = URL(fileURLWithPath: "/tmp/Greendale/study-group.mp4")
        weak var weakToken: Token?
        do {
            let token = Token()
            weakToken = token
            source.readyFile = {
                _ = token
                return sampleURL
            }
            source.file = {
                _ = token
                return sampleURL
            }
            source.fileName = {
                _ = token
                return "study-group.mp4"
            }
        }
        XCTAssertNotNil(weakToken)
        XCTAssertEqual(source.readyFile(), sampleURL)
        XCTAssertEqual(source.fileName(), "study-group.mp4")

        source.reset()

        XCTAssertNil(weakToken)
        XCTAssertNil(source.readyFile())
        XCTAssertEqual(source.fileName(), "Recording.mp4")
        do {
            _ = try await source.shareableFile()
            XCTFail("Expected reset share source to throw CancellationError")
        } catch is CancellationError {
            // Expected after reset.
        } catch {
            XCTFail("Unexpected error after reset: \(error)")
        }
    }

    func testExistingShareURLIgnoresMissingFilesOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Abed-ShareURL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent("Greendale-original.mp4")
        let exportedURL = directory.appendingPathComponent("Greendale-edited.mp4")
        try Data("video".utf8).write(to: exportedURL)

        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let tailID = try XCTUnwrap(edit.splitClip(at: 8))
        XCTAssertTrue(edit.deleteClip(id: tailID))
        let exported = ExportedVideo(edit: edit, url: exportedURL)

        XCTAssertEqual(
            PostRecordingLogic.existingShareURL(original: original, edit: edit, exportedVideo: exported),
            exportedURL
        )

        try FileManager.default.removeItem(at: exportedURL)
        XCTAssertNil(
            PostRecordingLogic.existingShareURL(original: original, edit: edit, exportedVideo: exported)
        )
    }

    func testShareTempStorageRemovesManagedAndStaleFoldersOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Jeff-ShareRoot-\(UUID().uuidString)", isDirectory: true)
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Jeff-External-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }

        let staleFolder = ShareTempStorage.makeFolder(in: root)
        let freshFolder = ShareTempStorage.makeFolder(in: root)
        try FileManager.default.createDirectory(at: staleFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshFolder, withIntermediateDirectories: true)
        let staleFile = staleFolder.appendingPathComponent("stale.mp4")
        let freshFile = freshFolder.appendingPathComponent("fresh.mp4")
        let externalFile = external.appendingPathComponent("user-export.mp4")
        try Data("stale".utf8).write(to: staleFile)
        try Data("fresh".utf8).write(to: freshFile)
        try Data("keep".utf8).write(to: externalFile)

        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-48 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: staleFolder.path)

        ShareTempStorage.cleanupStaleShareFolders(olderThan: 24 * 60 * 60, now: now, in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFolder.path))

        ShareTempStorage.removeManagedParentFolder(of: externalFile, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))

        ShareTempStorage.removeManagedParentFolder(of: freshFile, in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshFolder.path))
    }

    func testShouldDebounceSaveOnlyForContinuousZoomParameterChanges() throws {
        var base = try XCTUnwrap(TimelineEdit(sourceDuration: 10))
        let sceneID = try base.addZoomScene(span: TimelineSpan(start: 2, end: 4))

        var focalMoved = base
        try focalMoved.setZoomFocalPoint(try XCTUnwrap(UnitPoint2D(x: 0.25, y: 0.75)), for: sceneID)
        XCTAssertTrue(PostRecordingLogic.shouldDebounceSave(from: base, to: focalMoved))

        var settingsChanged = base
        try settingsChanged.setZoomSettings(
            ZoomSceneSettings(level: .init(scale: 2.0), transitionSpeed: .fast),
            for: sceneID
        )
        XCTAssertTrue(PostRecordingLogic.shouldDebounceSave(from: base, to: settingsChanged))

        var resized = base
        try resized.resizeZoomScene(id: sceneID, to: TimelineSpan(start: 1, end: 5))
        XCTAssertFalse(PostRecordingLogic.shouldDebounceSave(from: base, to: resized))

        var split = base
        _ = try XCTUnwrap(split.splitClip(at: 5))
        XCTAssertFalse(PostRecordingLogic.shouldDebounceSave(from: base, to: split))
    }

    func testGIFExporterOutputSizeFitsWithinMaxDimensionWithoutUpscaling() {
        XCTAssertEqual(
            GIFExporter.outputSize(for: CGSize(width: 1200, height: 600), maxDimension: 800),
            CGSize(width: 800, height: 400)
        )
        XCTAssertEqual(
            GIFExporter.outputSize(for: CGSize(width: 600, height: 1200), maxDimension: 800),
            CGSize(width: 400, height: 800)
        )
        XCTAssertEqual(
            GIFExporter.outputSize(for: CGSize(width: 300, height: 180), maxDimension: 800),
            CGSize(width: 300, height: 180)
        )
    }

    @MainActor
    func testGIFExporterRendersZoomedHighResVideoOffMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel-Troy-GIF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("Greendale-hires.mp4")
        try await Self.writeStripedVideo(to: sourceURL, width: 1200, height: 600, frameCount: 30)

        var edit = try XCTUnwrap(TimelineEdit(sourceDuration: 1.0))
        try edit.addZoomScene(
            span: TimelineSpan(start: 0.25, end: 1.0),
            focalPoint: try XCTUnwrap(UnitPoint2D(x: 0, y: 0.5)),
            settings: ZoomSceneSettings(
                level: ZoomSceneSettings.Level(scale: 2.0),
                transitionSpeed: .fast
            )
        )

        let outputURL = directory.appendingPathComponent("Greendale-zoomed.gif")
        var progressValues: [Double] = []
        try await GIFExporter.export(
            sourceURL: sourceURL,
            outputURL: outputURL,
            edit: edit,
            onProgress: { progressValues.append($0) }
        )

        XCTAssertEqual(progressValues.last, 1.0)
        XCTAssertEqual(progressValues, progressValues.sorted())

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let frameCount = CGImageSourceGetCount(source)
        XCTAssertEqual(frameCount, GIFExport.frames(edit: edit).times.count)
        XCTAssertGreaterThan(frameCount, 1)

        let firstFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(firstFrame.width, 800)
        XCTAssertEqual(firstFrame.height, 400)

        let unzoomedRight = try Self.sampledColor(from: firstFrame, normalizedX: 0.85)
        XCTAssertGreaterThan(Int(unzoomedRight.blue), Int(unzoomedRight.red) + 100)
        XCTAssertGreaterThan(Int(unzoomedRight.blue), Int(unzoomedRight.green) + 100)

        let zoomedIndex = frameCount / 2
        let zoomedFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, zoomedIndex, nil))
        XCTAssertEqual(zoomedFrame.width, 800)
        XCTAssertEqual(zoomedFrame.height, 400)

        // At 2x zoom anchored on the left edge, x=0.85 of the zoomed frame
        // lands inside the middle green stripe (source x = 0.425).
        let zoomedRight = try Self.sampledColor(from: zoomedFrame, normalizedX: 0.85)
        XCTAssertGreaterThan(Int(zoomedRight.green), Int(zoomedRight.red) + 100)
        XCTAssertGreaterThan(Int(zoomedRight.green), Int(zoomedRight.blue) + 100)
    }

    private static func writeStripedVideo(
        to outputURL: URL,
        width: Int,
        height: Int,
        frameCount: Int
    ) async throws {
        let frameRate: Int32 = 30
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30],
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let pixelBuffer = try makeStripedPixelBuffer(width: width, height: height)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            let time = CMTime(value: Int64(frame), timescale: frameRate)
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
        }

        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private static func makeStripedPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * bytesPerRow + column * 4
                if column < width / 3 {
                    bytes[offset] = 0
                    bytes[offset + 1] = 0
                    bytes[offset + 2] = 255
                } else if column < width * 2 / 3 {
                    bytes[offset] = 0
                    bytes[offset + 1] = 255
                    bytes[offset + 2] = 0
                } else {
                    bytes[offset] = 255
                    bytes[offset + 1] = 0
                    bytes[offset + 2] = 0
                }
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }

    private static func sampledColor(
        from image: CGImage,
        normalizedX: Double
    ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let x = Int(Double(image.width - 1) * normalizedX)
        let y = image.height / 2
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (bytes[0], bytes[1], bytes[2])
    }
}
