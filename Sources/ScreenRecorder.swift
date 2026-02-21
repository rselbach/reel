@preconcurrency import AVFoundation
import CoreImage
import os.log
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "ScreenRecorder")

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

    var countdownTargetFrame: CGRect? {
        switch recordingMode {
        case .display:
            guard selectedDisplayIndex < availableDisplays.count else { return nil }
            return availableDisplays[selectedDisplayIndex].frame
        case .window:
            return selectedWindow?.frame
        }
    }

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioCaptureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var cameraCaptureSession: AVCaptureSession?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var outputURL: URL?
    private let captureSessionQueue = DispatchQueue(label: "com.rselbach.reel.capture")

    // Thread-safe state for frame processing (accessed from ScreenCaptureKit callback queue)
    private let frameLock = NSLock()
    private nonisolated(unsafe) var latestCameraPixelBuffer: CVPixelBuffer?
    private nonisolated(unsafe) var frameWriter: FrameWriter?
    private nonisolated(unsafe) var isCaptureStopped = false  // Signals callbacks to bail out
    private let circularMaskCache = NSCache<NSString, CIImage>()

    private nonisolated func withFrameLock<T>(_ action: () -> T) -> T {
        frameLock.lock()
        defer { frameLock.unlock() }
        return action()
    }
    
    // Dynamic camera overlay position (normalized 0-1 coordinates, updated during drag)
    private nonisolated(unsafe) var currentCameraX: CGFloat = 1.0  // 0=left, 1=right
    private nonisolated(unsafe) var currentCameraY: CGFloat = 0.0  // 0=bottom, 1=top

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
        let cameraSize: CGFloat
        let cameraShape: AppSettings.CameraOverlayShape
        var hasWriteFailure = false
    }

    private var settings: AppSettings { AppSettings.shared }
    
    /// The active camera capture session, if camera recording is enabled.
    /// Used by CameraOverlayController to display live preview.
    var activeCameraCaptureSession: AVCaptureSession? { cameraCaptureSession }
    
    /// The bounds of the area being recorded (display or window frame).
    /// Used to position and constrain the camera overlay.
    var recordingBounds: CGRect? { countdownTargetFrame }

    func requestPermission() async {
        await updateShareableContent(updatePermissionState: true, failureMessage: "Permission denied")
    }

    func refreshWindows() async {
        guard hasPermission else { return }
        await updateShareableContent(updatePermissionState: false, failureMessage: "Failed to refresh windows")
    }

    private func updateShareableContent(updatePermissionState: Bool, failureMessage: String) async {
        do {
            let content = try await loadShareableContent()
            availableDisplays = content.displays
            availableWindows = content.windows
            if updatePermissionState {
                hasPermission = true
                errorMessage = nil
            }
        } catch {
            if updatePermissionState {
                hasPermission = false
            }
            errorMessage = "\(failureMessage): \(error.localizedDescription)"
        }
    }

    private func loadShareableContent() async throws -> (displays: [SCDisplay], windows: [SCWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let windows = content.windows.filter { window in
            window.isOnScreen &&
            window.frame.width > RecordingConstants.minimumWindowSize &&
            window.frame.height > RecordingConstants.minimumWindowSize &&
            window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        return (content.displays, windows)
    }

    private func captureDimensions(for display: SCDisplay) -> (width: Int, height: Int) {
        let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2.0
        return (
            width: Int(CGFloat(display.width) * scale),
            height: Int(CGFloat(display.height) * scale)
        )
    }

    private func captureDimensions(for window: SCWindow) -> (width: Int, height: Int) {
        let windowScreen = NSScreen.screens.first { $0.frame.intersects(window.frame) }
        let scale = windowScreen?.backingScaleFactor ?? 2.0
        return (
            width: Int(window.frame.width * scale),
            height: Int(window.frame.height * scale)
        )
    }

    func startRecording() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        // Reset stop signal for new recording
        resetCaptureStopSignal()

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
            let dimensions = captureDimensions(for: display)
            captureWidth = dimensions.width
            captureHeight = dimensions.height

        case .window:
            guard let window = selectedWindow else {
                errorMessage = "No window selected"
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let dimensions = captureDimensions(for: window)
            captureWidth = dimensions.width
            captureHeight = dimensions.height
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
            let failures = startCaptureSessions()
            isRecording = true

            // Surface capture session failures as warnings (recording continues without them)
            if failures.audioFailed && failures.cameraFailed {
                errorMessage = "Audio and camera failed to start"
            } else if failures.audioFailed {
                errorMessage = "Audio failed to start"
            } else if failures.cameraFailed {
                errorMessage = "Camera failed to start"
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = "Failed to start: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stopRecording() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        // Signal callbacks to stop processing immediately
        signalCaptureStop()

        stopCaptureSessions()

        do {
            try await stream?.stopCapture()
        } catch {
            errorMessage = "Failed to stop capture: \(error.localizedDescription)"
        }

        await finalizeRecording()
        cleanup()
        isRecording = false
    }
    
    private nonisolated func signalCaptureStop() {
        withFrameLock {
            isCaptureStopped = true
        }
    }
    
    private nonisolated func resetCaptureStopSignal() {
        withFrameLock {
            isCaptureStopped = false
        }
    }

    /// Updates the camera overlay position during recording.
    /// Called from the draggable overlay window on the main thread.
    /// - Parameters:
    ///   - x: Normalized X position (0.0 = left edge, 1.0 = right edge)
    ///   - y: Normalized Y position (0.0 = bottom edge, 1.0 = top edge)
    func updateCameraOverlayPosition(x: CGFloat, y: CGFloat) {
        withFrameLock {
            currentCameraX = min(max(x, 0), 1)
            currentCameraY = min(max(y, 0), 1)
        }
    }

    private func setupAssetWriter(width: Int, height: Int) throws {
        let outputURL = try makeOutputURL()
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = makeVideoInput(width: width, height: height)

        guard assetWriter.canAdd(videoInput) else {
            throw NSError(domain: "ScreenRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }

        assetWriter.add(videoInput)

        let adaptor = makePixelBufferAdaptor(videoInput: videoInput, width: width, height: height)
        let context = CIContext()
        let bufferPool = makeBufferPool(width: width, height: height)
        let audioInput = settings.recordAudio ? makeAudioInput(assetWriter: assetWriter) : nil

        updateFrameWriter(
            adaptor: adaptor,
            videoInput: videoInput,
            audioInput: audioInput,
            assetWriter: assetWriter,
            context: context,
            bufferPool: bufferPool
        )

        self.outputURL = outputURL
        self.assetWriter = assetWriter
        self.videoInput = videoInput
        self.audioInput = audioInput

        guard assetWriter.startWriting() else {
            let reason = assetWriter.error?.localizedDescription ?? "Unknown writer error"
            throw NSError(
                domain: "ScreenRecorder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot start writer: \(reason)"]
            )
        }
    }

    private func makeOutputURL() throws -> URL {
        let outputDir = settings.outputDirectory

        if !FileManager.default.fileExists(atPath: outputDir.path()) {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        while true {
            let randomID = UUID().uuidString.prefix(8)
            let candidate = outputDir.appendingPathComponent("Reel-\(timestamp)-\(randomID).mp4")
            if !FileManager.default.fileExists(atPath: candidate.path()) {
                return candidate
            }
        }
    }

    private func makeVideoInput(width: Int, height: Int) -> AVAssetWriterInput {
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoQuality.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func makePixelBufferAdaptor(
        videoInput: AVAssetWriterInput,
        width: Int,
        height: Int
    ) -> AVAssetWriterInputPixelBufferAdaptor {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        return AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
    }

    private func makeBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
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
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &bufferPool
        )
        if poolStatus != kCVReturnSuccess {
            logger.warning("Failed to create pixel buffer pool (status: \(poolStatus)). Camera compositing may use fallback allocation.")
        }
        return bufferPool
    }

    private func makeAudioInput(assetWriter: AVAssetWriter) -> AVAssetWriterInput? {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        if assetWriter.canAdd(input) {
            assetWriter.add(input)
            return input
        }

        logger.warning("Unable to add audio input to asset writer")
        return nil
    }

    private func updateFrameWriter(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        videoInput: AVAssetWriterInput,
        audioInput: AVAssetWriterInput?,
        assetWriter: AVAssetWriter,
        context: CIContext,
        bufferPool: CVPixelBufferPool?
    ) {
        let initialPos = settings.cameraPosition.normalizedCoordinates
        withFrameLock {
            currentCameraX = initialPos.x
            currentCameraY = initialPos.y
            frameWriter = FrameWriter(
                adaptor: adaptor,
                videoInput: videoInput,
                audioInput: audioInput,
                assetWriter: assetWriter,
                ciContext: context,
                bufferPool: bufferPool,
                startTime: nil,
                recordCamera: settings.recordCamera,
                cameraSize: settings.cameraSize.fraction,
                cameraShape: settings.cameraShape
            )
        }
    }

    private func buildCaptureSession(
        device: AVCaptureDevice,
        output: AVCaptureOutput,
        outputQueue: DispatchQueue,
        configureSession: (AVCaptureSession) -> Void = { _ in },
        configureOutput: (AVCaptureOutput) -> Void = { _ in }
    ) throws -> AVCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()
        configureSession(session)

        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        configureOutput(output)

        if let audioOutput = output as? AVCaptureAudioDataOutput {
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
        }

        if let videoOutput = output as? AVCaptureVideoDataOutput {
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        }

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
        return session
    }

    private func setupAudioCapture() throws {
        guard let device = settings.selectedAudioDevice else {
            throw NSError(domain: "ScreenRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio device available"])
        }

        let output = AVCaptureAudioDataOutput()
        let session = try buildCaptureSession(
            device: device,
            output: output,
            outputQueue: DispatchQueue(label: "audio.capture.queue")
        )

        audioCaptureSession = session
        audioOutput = output
    }

    private func setupCameraCapture() throws {
        guard let device = settings.selectedCamera else {
            throw NSError(domain: "ScreenRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No camera available"])
        }

        let output = AVCaptureVideoDataOutput()
        let session = try buildCaptureSession(
            device: device,
            output: output,
            outputQueue: DispatchQueue(label: "camera.capture.queue"),
            configureSession: { session in
                session.sessionPreset = .high
            },
            configureOutput: { output in
                if let videoOutput = output as? AVCaptureVideoDataOutput {
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                }
            }
        )

        cameraCaptureSession = session
        cameraOutput = output
    }

    private func finalizeRecording() async {
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await assetWriter?.finishWriting()

        guard let tempURL = outputURL else { return }
        guard let assetWriter else { return }
        guard assetWriter.status == .completed else {
            let reason = assetWriter.error?.localizedDescription ?? "Writer status: \(assetWriter.status.rawValue)"
            errorMessage = "Failed to finalize recording: \(reason)"
            discardTempRecording(tempURL)
            return
        }

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
                    try moveTempRecording(from: tempURL, to: finalURL)
                } catch {
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                    discardTempRecording(tempURL)
                    return
                }
            } else {
                finalURL = tempURL
            }
        }

        logger.info("Recording saved to: \(finalURL.path())")
        lastRecordedURL = finalURL

        if settings.openFinderAfterRecording && !settings.showPreviewAfterRecording {
            NSWorkspace.shared.selectFile(finalURL.path(), inFileViewerRootedAtPath: "")
        }
    }

    private func moveTempRecording(from tempURL: URL, to finalURL: URL) throws {
        if finalURL == tempURL {
            logger.info("Recording already at final location, skipping move")
            return
        }

        if FileManager.default.fileExists(atPath: finalURL.path()) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }

    private func discardTempRecording(_ tempURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: tempURL.path()) {
                try FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            logger.error("Failed to remove temporary recording at \(tempURL.path(), privacy: .public): \(error.localizedDescription, privacy: .public)")
            if errorMessage == nil {
                errorMessage = "Failed to clean up temporary recording: \(error.localizedDescription)"
            }
        }
        lastRecordedURL = nil
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
        withFrameLock {
            latestCameraPixelBuffer = nil
            frameWriter = nil
        }
    }

    private func startCaptureSessions() -> (audioFailed: Bool, cameraFailed: Bool) {
        let audioSession = audioCaptureSession
        let cameraSession = cameraCaptureSession
        var audioFailed = false
        var cameraFailed = false

        captureSessionQueue.sync {
            if let audio = audioSession {
                audio.startRunning()
                if !audio.isRunning {
                    logger.error("Audio capture session failed to start")
                    audioFailed = true
                }
            }
            if let camera = cameraSession {
                camera.startRunning()
                if !camera.isRunning {
                    logger.error("Camera capture session failed to start")
                    cameraFailed = true
                }
            }
        }

        return (audioFailed, cameraFailed)
    }

    private func stopCaptureSessions() {
        let audioSession = audioCaptureSession
        let cameraSession = cameraCaptureSession
        captureSessionQueue.sync {
            audioSession?.stopRunning()
            cameraSession?.stopRunning()
        }
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
        xNormalized: CGFloat,
        yNormalized: CGFloat,
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

            let cacheKey = "\(Int(overlayWidth.rounded()))x\(Int(overlayHeight.rounded()))"
            let gradientOutput: CIImage
            if let cached = circularMaskCache.object(forKey: cacheKey as NSString) {
                gradientOutput = cached
            } else {
                guard let radialGradient = CIFilter(name: "CIRadialGradient") else { return nil }
                radialGradient.setValue(CIVector(x: centerX, y: centerY), forKey: "inputCenter")
                radialGradient.setValue(radius - 1, forKey: "inputRadius0")
                radialGradient.setValue(radius, forKey: "inputRadius1")
                radialGradient.setValue(CIColor.white, forKey: "inputColor0")
                radialGradient.setValue(CIColor.clear, forKey: "inputColor1")

                guard let cachedOutput = radialGradient.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight)) else { return nil }
                circularMaskCache.setObject(cachedOutput, forKey: cacheKey as NSString)
                gradientOutput = cachedOutput
            }

            cameraImage = cameraImage.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: gradientOutput
            ])
        }

        // Position the overlay using normalized coordinates
        // X: 0 = left edge (with padding), 1 = right edge (with padding)
        // Y: 0 = bottom edge (with padding), 1 = top edge (with padding)
        let padding: CGFloat = RecordingConstants.cameraOverlayPadding
        let availableWidth = screenWidth - overlayWidth - (padding * 2)
        let availableHeight = screenHeight - overlayHeight - (padding * 2)
        let xOffset = padding + (xNormalized * availableWidth)
        let yOffset = padding + (yNormalized * availableHeight)

        cameraImage = cameraImage.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))

        let composited = cameraImage.composited(over: screenImage)

        var outputBuffer: CVPixelBuffer?
        let status: CVReturn
        if let bufferPool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &outputBuffer)
        } else {
            // Fallback if pool not available
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(screenWidth),
                Int(screenHeight),
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &outputBuffer
            )
        }

        if status != kCVReturnSuccess {
            logger.warning("Failed to create output pixel buffer (status: \(status))")
        }

        guard let outputBuffer else { return nil }
        context.render(composited, to: outputBuffer)

        return outputBuffer
    }

    private nonisolated func handleAppendFailure(_ writer: inout FrameWriter, context: String) {
        writer.hasWriteFailure = true
        let reason = writer.assetWriter.error?.localizedDescription ?? "Unknown writer error"
        logger.error("\(context, privacy: .public): \(reason, privacy: .public)")
        Task { @MainActor in
            errorMessage = "\(context): \(reason)"
        }
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

        var writerSnapshot: FrameWriter?
        var cameraBuffer: CVPixelBuffer?
        var cameraX: CGFloat = 0
        var cameraY: CGFloat = 0

        withFrameLock {
            guard !isCaptureStopped else { return }
            guard var writer = frameWriter else { return }
            guard !writer.hasWriteFailure else { return }

            cameraBuffer = latestCameraPixelBuffer

            if writer.startTime == nil {
                writer.startTime = presentationTime
                writer.assetWriter.startSession(atSourceTime: presentationTime)
                frameWriter = writer
            }

            guard writer.videoInput.isReadyForMoreMediaData else { return }

            cameraX = currentCameraX
            cameraY = currentCameraY
            writerSnapshot = writer
        }

        guard let snapshot = writerSnapshot else { return }

        var frameToWrite = screenBuffer
        var usedCompositedBuffer = false

        if snapshot.recordCamera, let cameraBuffer {
            if let composited = compositeFrame(
                screenBuffer: screenBuffer,
                cameraBuffer: cameraBuffer,
                context: snapshot.ciContext,
                bufferPool: snapshot.bufferPool,
                xNormalized: cameraX,
                yNormalized: cameraY,
                sizeFraction: snapshot.cameraSize,
                shape: snapshot.cameraShape
            ) {
                frameToWrite = composited
                usedCompositedBuffer = true
            } else {
                logger.warning("Camera compositing failed, using screen-only frame")
            }
        }

        withFrameLock {
            guard !isCaptureStopped else { return }
            guard var writer = frameWriter else { return }
            guard !writer.hasWriteFailure else { return }
            guard writer.videoInput.isReadyForMoreMediaData else { return }

            if !writer.adaptor.append(frameToWrite, withPresentationTime: presentationTime) {
                let context = usedCompositedBuffer
                    ? "Failed to append composited video frame"
                    : "Failed to append video frame"
                handleAppendFailure(&writer, context: context)
                frameWriter = writer
                isCaptureStopped = true
                return
            }
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
            let stored = withFrameLock { () -> Bool in
                guard !isCaptureStopped else { return false }
                latestCameraPixelBuffer = copiedBuffer
                return true
            }
            guard stored else { return }
        } else if output is AVCaptureAudioDataOutput {
            let writer = withFrameLock { () -> FrameWriter? in
                guard !isCaptureStopped else { return nil }
                return frameWriter
            }

            guard var writer,
                  writer.startTime != nil,
                  let audio = writer.audioInput,
                  audio.isReadyForMoreMediaData
            else { return }

            if !audio.append(sampleBuffer) {
                withFrameLock {
                    handleAppendFailure(&writer, context: "Failed to append audio sample")
                    frameWriter = writer
                    isCaptureStopped = true
                }
            }
        }
    }
}
