import AVFoundation
import CoreImage
import os.log
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.reel", category: "ScreenRecorder")

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

enum RecordingMode {
    case display
    case window
}

private enum RecordingConstants {
    /// Minimum dimensions for windows to appear in the picker (filters tiny/hidden windows)
    static let minimumWindowSize: CGFloat = 100
    /// Padding from screen edge for camera overlay (in points, doubled for Retina)
    static let cameraOverlayPadding: CGFloat = 40
}

@MainActor
class ScreenRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false {
        didSet {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.updateIcon(isRecording: isRecording)
            }
        }
    }
    private var isStarting = false
    private var isStopping = false
    @Published var hasPermission = false
    @Published var availableDisplays: [SCDisplay] = []
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedDisplayIndex = 0
    @Published var selectedWindow: SCWindow?
    @Published var recordingMode: RecordingMode = .display
    @Published var errorMessage: String?
    @Published var lastRecordedURL: URL?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioCaptureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var cameraCaptureSession: AVCaptureSession?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var outputURL: URL?

    // Thread-safe state for frame processing (accessed from ScreenCaptureKit callback queue)
    private let frameLock = NSLock()
    private nonisolated(unsafe) var latestCameraPixelBuffer: CVPixelBuffer?
    private nonisolated(unsafe) var frameWriter: FrameWriter?

    // Encapsulates frame writing state for thread-safe access
    private struct FrameWriter {
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let assetWriter: AVAssetWriter
        let ciContext: CIContext
        let bufferPool: CVPixelBufferPool?
        var startTime: CMTime?
        let recordCamera: Bool
        let cameraPosition: AppSettings.CameraOverlayPosition
        let cameraSize: CGFloat
        let cameraShape: AppSettings.CameraOverlayShape
    }

    private var settings: AppSettings { AppSettings.shared }

    func requestPermission() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            availableDisplays = content.displays
            availableWindows = content.windows.filter { window in
                window.isOnScreen &&
                window.frame.width > RecordingConstants.minimumWindowSize &&
                window.frame.height > RecordingConstants.minimumWindowSize &&
                window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            hasPermission = true
            errorMessage = nil
        } catch {
            hasPermission = false
            errorMessage = "Permission denied: \(error.localizedDescription)"
        }
    }

    func refreshWindows() async {
        guard hasPermission else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            availableDisplays = content.displays
            availableWindows = content.windows.filter { window in
                window.isOnScreen &&
                window.frame.width > RecordingConstants.minimumWindowSize &&
                window.frame.height > RecordingConstants.minimumWindowSize &&
                window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
        } catch {
            errorMessage = "Failed to refresh windows: \(error.localizedDescription)"
        }
    }

    func startRecording() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let filter: SCContentFilter
        let captureWidth: Int
        let captureHeight: Int

        switch recordingMode {
        case .display:
            guard selectedDisplayIndex < availableDisplays.count else {
                errorMessage = "No display selected"
                return
            }
            let display = availableDisplays[selectedDisplayIndex]
            filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2.0
            captureWidth = Int(CGFloat(display.width) * scale)
            captureHeight = Int(CGFloat(display.height) * scale)

        case .window:
            guard let window = selectedWindow else {
                errorMessage = "No window selected"
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let windowScreen = NSScreen.screens.first { $0.frame.intersects(window.frame) }
            let scale = windowScreen?.backingScaleFactor ?? 2.0
            captureWidth = Int(window.frame.width * scale)
            captureHeight = Int(window.frame.height * scale)
        }

        do {
            let config = SCStreamConfiguration()
            config.width = captureWidth
            config.height = captureHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            config.queueDepth = 5
            config.showsCursor = settings.showCursor
            config.pixelFormat = kCVPixelFormatType_32BGRA

            try setupAssetWriter(width: config.width, height: config.height)

            if settings.recordAudio {
                try setupAudioCapture()
            }

            if settings.recordCamera {
                try setupCameraCapture()
            }

            stream = SCStream(filter: filter, configuration: config, delegate: self)

            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())

            try await stream?.startCapture()
            audioCaptureSession?.startRunning()
            cameraCaptureSession?.startRunning()
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = "Failed to start: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stopRecording() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        audioCaptureSession?.stopRunning()
        cameraCaptureSession?.stopRunning()

        do {
            try await stream?.stopCapture()
        } catch {
            errorMessage = "Failed to stop capture: \(error.localizedDescription)"
        }

        await finalizeRecording()
        cleanup()
        isRecording = false
    }

    private func setupAssetWriter(width: Int, height: Int) throws {
        let outputDir = settings.outputDirectory

        // Ensure output directory exists
        if !FileManager.default.fileExists(atPath: outputDir.path()) {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = outputDir.appendingPathComponent("Reel-\(timestamp).mp4")
        outputURL = url

        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoQuality.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true

        if let videoInput, let assetWriter, assetWriter.canAdd(videoInput) {
            assetWriter.add(videoInput)

            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )
            let context = CIContext()

            // Create buffer pool for camera compositing
            var bufferPool: CVPixelBufferPool?
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 3
            ]
            let bufferAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                bufferAttributes as CFDictionary,
                &bufferPool
            )

            // Set up audio input before creating FrameWriter so it can be included
            if settings.recordAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000
                ]
                audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput?.expectsMediaDataInRealTime = true

                if let audioInput, assetWriter.canAdd(audioInput) {
                    assetWriter.add(audioInput)
                }
            }

            // Create frame writer with captured settings for thread-safe access
            frameLock.lock()
            frameWriter = FrameWriter(
                adaptor: adaptor,
                videoInput: videoInput,
                audioInput: audioInput,
                assetWriter: assetWriter,
                ciContext: context,
                bufferPool: bufferPool,
                startTime: nil,
                recordCamera: settings.recordCamera,
                cameraPosition: settings.cameraPosition,
                cameraSize: settings.cameraSize.fraction,
                cameraShape: settings.cameraShape
            )
            frameLock.unlock()
        }

        assetWriter?.startWriting()
    }

    private func setupAudioCapture() throws {
        guard let device = settings.selectedAudioDevice else {
            throw NSError(domain: "ScreenRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio device available"])
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "audio.capture.queue"))
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()

        audioCaptureSession = session
        audioOutput = output
    }

    private func setupCameraCapture() throws {
        guard let device = settings.selectedCamera else {
            throw NSError(domain: "ScreenRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No camera available"])
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.capture.queue"))
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()

        cameraCaptureSession = session
        cameraOutput = output
    }

    private func finalizeRecording() async {
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await assetWriter?.finishWriting()

        guard let tempURL = outputURL else { return }

        var finalURL = tempURL

        if settings.askWhereToSave {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = tempURL.lastPathComponent
            panel.directoryURL = settings.outputDirectory

            let response: NSApplication.ModalResponse
            if let keyWindow = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: keyWindow)
            } else {
                response = panel.runModal()
            }
            if response == .OK, let url = panel.url {
                finalURL = url
                do {
                    // Remove existing file if user confirmed overwrite in save panel
                    if FileManager.default.fileExists(atPath: finalURL.path()) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                } catch {
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }
            } else {
                try? FileManager.default.removeItem(at: tempURL)
                lastRecordedURL = nil
                return
            }
        }

        logger.info("Recording saved to: \(finalURL.path())")
        lastRecordedURL = finalURL

        if settings.openFinderAfterRecording && !settings.showPreviewAfterRecording {
            NSWorkspace.shared.selectFile(finalURL.path(), inFileViewerRootedAtPath: "")
        }
    }

    private func cleanup() {
        stream = nil
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        audioCaptureSession = nil
        audioOutput = nil
        cameraCaptureSession = nil
        cameraOutput = nil
        frameLock.lock()
        latestCameraPixelBuffer = nil
        frameWriter = nil
        frameLock.unlock()
    }

    /// Creates a copy of a pixel buffer to ensure it remains valid independently.
    /// Only works with non-planar formats (e.g., BGRA). Planar formats require per-plane copying.
    private nonisolated func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        // Only non-planar formats are supported
        guard CVPixelBufferGetPlaneCount(source) == 0 else {
            logger.warning("copyPixelBuffer called with planar format, skipping")
            return nil
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        var destBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            nil,
            &destBuffer
        )

        guard status == kCVReturnSuccess, let dest = destBuffer else {
            logger.warning("Failed to create pixel buffer copy (status: \(status))")
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let destBase = CVPixelBufferGetBaseAddress(dest) else {
            logger.warning("Failed to get pixel buffer base address")
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(dest)

        // Copy row by row to handle different bytesPerRow (padding) between buffers
        let bytesToCopy = min(srcBytesPerRow, destBytesPerRow)
        for row in 0..<height {
            let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
            let destRow = destBase.advanced(by: row * destBytesPerRow)
            memcpy(destRow, srcRow, bytesToCopy)
        }

        return dest
    }

    nonisolated func compositeFrame(
        screenBuffer: CVPixelBuffer,
        cameraBuffer: CVPixelBuffer?,
        context: CIContext,
        bufferPool: CVPixelBufferPool?,
        position: AppSettings.CameraOverlayPosition,
        sizeFraction: CGFloat,
        shape: AppSettings.CameraOverlayShape
    ) -> CVPixelBuffer? {
        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        let screenWidth = CGFloat(CVPixelBufferGetWidth(screenBuffer))
        let screenHeight = CGFloat(CVPixelBufferGetHeight(screenBuffer))

        guard let cameraBuffer else { return nil }

        var cameraImage = CIImage(cvPixelBuffer: cameraBuffer)
        let cameraWidth = CGFloat(CVPixelBufferGetWidth(cameraBuffer))
        let cameraHeight = CGFloat(CVPixelBufferGetHeight(cameraBuffer))

        let overlayWidth = screenWidth * sizeFraction
        let scale = overlayWidth / cameraWidth
        let overlayHeight = cameraHeight * scale

        cameraImage = cameraImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if shape == .circle {
            let diameter = min(overlayWidth, overlayHeight)
            let centerX = overlayWidth / 2
            let centerY = overlayHeight / 2
            let radius = diameter / 2

            guard let radialGradient = CIFilter(name: "CIRadialGradient") else { return nil }
            radialGradient.setValue(CIVector(x: centerX, y: centerY), forKey: "inputCenter")
            radialGradient.setValue(radius - 1, forKey: "inputRadius0")
            radialGradient.setValue(radius, forKey: "inputRadius1")
            radialGradient.setValue(CIColor.white, forKey: "inputColor0")
            radialGradient.setValue(CIColor.clear, forKey: "inputColor1")

            guard let gradientOutput = radialGradient.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight)) else { return nil }

            cameraImage = cameraImage.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: gradientOutput
            ])
        }

        let padding: CGFloat = RecordingConstants.cameraOverlayPadding
        let xOffset: CGFloat
        let yOffset: CGFloat

        switch position {
        case .bottomLeft:
            xOffset = padding
            yOffset = padding
        case .bottomRight:
            xOffset = screenWidth - overlayWidth - padding
            yOffset = padding
        case .topLeft:
            xOffset = padding
            yOffset = screenHeight - overlayHeight - padding
        case .topRight:
            xOffset = screenWidth - overlayWidth - padding
            yOffset = screenHeight - overlayHeight - padding
        }

        cameraImage = cameraImage.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))

        let composited = cameraImage.composited(over: screenImage)

        var outputBuffer: CVPixelBuffer?
        if let bufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &outputBuffer)
        } else {
            // Fallback if pool not available
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(screenWidth),
                Int(screenHeight),
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &outputBuffer
            )
        }

        guard let outputBuffer else { return nil }
        context.render(composited, to: outputBuffer)

        return outputBuffer
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            errorMessage = "Stream stopped: \(error.localizedDescription)"
            isRecording = false
            cleanup()
        }
    }
}

extension ScreenRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else { return }

        guard let screenBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Process frame synchronously to avoid buffer lifetime issues
        frameLock.lock()
        defer { frameLock.unlock() }

        guard var writer = frameWriter else { return }
        let cameraBuffer = latestCameraPixelBuffer

        // Start session on first frame
        if writer.startTime == nil {
            writer.startTime = presentationTime
            writer.assetWriter.startSession(atSourceTime: presentationTime)
            frameWriter = writer
        }

        guard writer.videoInput.isReadyForMoreMediaData else { return }

        if writer.recordCamera, cameraBuffer != nil {
            if let composited = compositeFrame(
                screenBuffer: screenBuffer,
                cameraBuffer: cameraBuffer,
                context: writer.ciContext,
                bufferPool: writer.bufferPool,
                position: writer.cameraPosition,
                sizeFraction: writer.cameraSize,
                shape: writer.cameraShape
            ) {
                writer.adaptor.append(composited, withPresentationTime: presentationTime)
            } else {
                // Compositing failed, fall back to screen-only frame
                logger.warning("Camera compositing failed, using screen-only frame")
                writer.adaptor.append(screenBuffer, withPresentationTime: presentationTime)
            }
        } else {
            writer.adaptor.append(screenBuffer, withPresentationTime: presentationTime)
        }
    }
}

extension ScreenRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }

        if output is AVCaptureVideoDataOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            // Copy the pixel buffer to ensure it remains valid after callback returns
            guard let copiedBuffer = copyPixelBuffer(pixelBuffer) else { return }
            frameLock.lock()
            latestCameraPixelBuffer = copiedBuffer
            frameLock.unlock()
        } else if output is AVCaptureAudioDataOutput {
            frameLock.lock()
            let writer = frameWriter
            frameLock.unlock()

            guard let writer,
                  writer.startTime != nil,
                  let audio = writer.audioInput,
                  audio.isReadyForMoreMediaData
            else { return }

            audio.append(sampleBuffer)
        }
    }
}
