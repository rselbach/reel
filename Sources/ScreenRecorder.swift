@preconcurrency import AVFoundation
import CoreImage
import CoreText
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

private enum RecordingError: LocalizedError {
    case outputDirectoryCreationFailed(URL, Error)
    case outputDirectoryNotWritable(URL)

    var errorDescription: String? {
        switch self {
        case .outputDirectoryCreationFailed(let url, let error):
            "Unable to prepare output directory \(url.path()): \(error.localizedDescription)"
        case .outputDirectoryNotWritable(let url):
            "Output directory is not writable: \(url.path())"
        }
    }
}

private struct TextOverlay {
    let text: String
    let position: AppSettings.TextOverlayPosition
}

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
    let textOverlay: TextOverlay?
    var hasWriteFailure = false
}

private final class FrameCaptureState {
    var latestCameraPixelBuffer: CVPixelBuffer?
    var frameWriter: FrameWriter?
    var isCaptureStopped = false
    var currentCameraX: CGFloat = 1.0
    var currentCameraY: CGFloat = 0.0
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
    // Recommended audio settings captured from the configured AVCaptureSession;
    // used to build the asset writer input so it matches the source format
    // instead of a hardcoded 44100/2ch/128k.
    private var audioOutputSettings: [String: Any]?
    private var cameraCaptureSession: AVCaptureSession?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var outputURL: URL?
    private let captureSessionQueue = DispatchQueue(label: "com.rselbach.reel.capture")
    // Reused across recordings; CIContext is cheap to hold but unnecessary
    // to recreate per recording.
    private let ciContext = CIContext()
    // Serial queue for SCStream frame output. Apple requires a serial queue;
    // a concurrent queue can deliver frames out of presentation-time order,
    // which corrupts AVAssetWriterInput appends (timestamps must be monotonic).
    private let streamOutputQueue = DispatchQueue(label: "com.rselbach.reel.stream-output")

    // Thread-safe state for frame processing (accessed from ScreenCaptureKit callback queue)
    private nonisolated(unsafe) let frameState = FrameCaptureState()
    private let frameLock = NSLock()
    private nonisolated(unsafe) let circularMaskCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 4
        return cache
    }()
    private nonisolated(unsafe) let textOverlayCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 8
        return cache
    }()

    private nonisolated func withFrameLock<T>(_ action: () -> T) -> T {
        frameLock.lock()
        defer { frameLock.unlock() }
        return action()
    }
    
    // Dynamic camera overlay position (normalized 0-1 coordinates, updated during drag)
    

    private var settings: AppSettings { AppSettings.shared }
    
    /// The active camera capture session, if camera recording is enabled.
    /// Used by CameraOverlayController to display live preview.
    var activeCameraCaptureSession: AVCaptureSession? { cameraCaptureSession }
    
    /// The bounds of the area being recorded, in Cocoa coordinates (origin
    /// bottom-left), for positioning and constraining the camera overlay.
    /// `SCDisplay.frame`/`SCWindow.frame` are Quartz coords (origin top-left);
    /// converting here keeps the overlay correct on non-main displays.
    var recordingBounds: CGRect? {
        guard let quartzFrame = countdownTargetFrame else { return nil }
        return cocoaRect(fromQuartz: quartzFrame)
    }

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
            availableDisplays = []
            availableWindows = []
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

        guard captureWidth > 0, captureHeight > 0 else {
            errorMessage = "Invalid recording dimensions"
            return
        }

        do {
            let config = SCStreamConfiguration()
            config.width = captureWidth
            config.height = captureHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            config.queueDepth = 5
            config.showsCursor = settings.showCursor
            config.pixelFormat = kCVPixelFormatType_32BGRA

            // Request AVFoundation permissions before allocating any recording
            // resources, so a denial surfaces a clear message instead of a
            // generic "Failed to start" and leaves no temp file behind.
            if settings.recordAudio {
                guard await ensureAVPermission(for: .audio) else {
                    errorMessage = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
                    return
                }
            }

            if settings.recordCamera {
                guard await ensureAVPermission(for: .video) else {
                    errorMessage = "Camera access denied. Enable it in System Settings → Privacy & Security → Camera."
                    return
                }
            }

            // Set up capture sessions before the asset writer so the audio
            // input can use the source's recommended settings (makeAudioInput).
            if settings.recordAudio {
                try setupAudioCapture()
            }

            if settings.recordCamera {
                try setupCameraCapture()
            }

            try setupAssetWriter(width: config.width, height: config.height)

            stream = SCStream(filter: filter, configuration: config, delegate: self)

            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamOutputQueue)

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
            frameState.isCaptureStopped = true
        }
    }
    
    private nonisolated func resetCaptureStopSignal() {
        withFrameLock {
            frameState.isCaptureStopped = false
        }
    }

    /// Updates the camera overlay position during recording.
    /// Called from the draggable overlay window on the main thread.
    /// - Parameters:
    ///   - x: Normalized X position (0.0 = left edge, 1.0 = right edge)
    ///   - y: Normalized Y position (0.0 = bottom edge, 1.0 = top edge)
    func updateCameraOverlayPosition(x: CGFloat, y: CGFloat) {
        withFrameLock {
            frameState.currentCameraX = min(max(x, 0), 1)
            frameState.currentCameraY = min(max(y, 0), 1)
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
        let bufferPool = makeBufferPool(width: width, height: height)
        let audioInput = settings.recordAudio ? makeAudioInput(assetWriter: assetWriter) : nil

        updateFrameWriter(
            adaptor: adaptor,
            videoInput: videoInput,
            audioInput: audioInput,
            assetWriter: assetWriter,
            context: ciContext,
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
        do {
            return try makeOutputURL(in: outputDir)
        } catch {
            logger.warning("Configured output directory unavailable (\(outputDir.path()), using fallback: \(error.localizedDescription))")
            let fallback = AppSettings.defaultOutputDirectory()
            persistSettingOutputDirectory(fallback)
            return try makeOutputURL(in: fallback)
        }
    }

    private func makeOutputURL(in outputDir: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            throw RecordingError.outputDirectoryCreationFailed(outputDir, error)
        }

        let values: URLResourceValues
        do {
            values = try outputDir.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        } catch {
            throw RecordingError.outputDirectoryCreationFailed(outputDir, error)
        }

        guard values.isDirectory == true else {
            throw RecordingError.outputDirectoryCreationFailed(
                outputDir,
                NSError(domain: "ScreenRecorder", code: 6, userInfo: [NSLocalizedDescriptionKey: "Output path is not a directory"])
            )
        }

        if values.isWritable != true {
            throw RecordingError.outputDirectoryNotWritable(outputDir)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        for _ in 0..<64 {
            let randomID = UUID().uuidString.prefix(8)
            let candidate = outputDir.appendingPathComponent("Reel-\(timestamp)-\(randomID).mp4")
            if !FileManager.default.fileExists(atPath: candidate.path()) {
                return candidate
            }
        }

        throw RecordingError.outputDirectoryCreationFailed(
            outputDir,
            NSError(
                domain: "ScreenRecorder",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Unable to generate unique recording filename"]
            )
        )
    }

    private func persistSettingOutputDirectory(_ url: URL) {
        settings.outputDirectory = url
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
        let audioSettings: [String: Any]
        if let recommended = audioOutputSettings, !recommended.isEmpty {
            audioSettings = recommended
        } else {
            // Fallback when no source format is known.
            audioSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
        }
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
        let textOverlay = settings.activeTextOverlayText.map {
            TextOverlay(text: $0, position: settings.textOverlayPosition)
        }
        withFrameLock {
            frameState.currentCameraX = initialPos.x
            frameState.currentCameraY = initialPos.y
            frameState.frameWriter = FrameWriter(
                adaptor: adaptor,
                videoInput: videoInput,
                audioInput: audioInput,
                assetWriter: assetWriter,
                ciContext: context,
                bufferPool: bufferPool,
                startTime: nil,
                recordCamera: settings.recordCamera,
                cameraSize: settings.cameraSize.fraction,
                cameraShape: settings.cameraShape,
                textOverlay: textOverlay
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

    private func ensureAVPermission(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
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
        // recommendedAudioSettingsForAssetWriter requires the output to be
        // attached to a configured session; capture it now so the writer input
        // matches the actual source sample rate/channels.
        audioOutputSettings = output.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
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
        do {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            logger.warning("Move failed for recording file, attempting copy fallback: \(error.localizedDescription)")
            do {
                try FileManager.default.copyItem(at: tempURL, to: finalURL)
                if FileManager.default.fileExists(atPath: tempURL.path()) {
                    do {
                        try FileManager.default.removeItem(at: tempURL)
                    } catch {
                        logger.warning("Failed to remove temporary recording after copy: \(error.localizedDescription)")
                        throw error
                    }
                }
            } catch {
                throw error
            }
        }
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
        audioOutputSettings = nil
        cameraCaptureSession = nil
        cameraOutput = nil
        circularMaskCache.removeAllObjects()
        textOverlayCache.removeAllObjects()
        withFrameLock {
            frameState.latestCameraPixelBuffer = nil
            frameState.frameWriter = nil
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

        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLock == kCVReturnSuccess else {
            logger.warning("Failed to lock source pixel buffer (status: \(sourceLock))")
            return nil
        }
        let destLock = CVPixelBufferLockBaseAddress(dest, [])
        guard destLock == kCVReturnSuccess else {
            logger.warning("Failed to lock destination pixel buffer (status: \(destLock))")
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            return nil
        }
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
        let totalBytes = srcBytesPerRow * height

        if srcBytesPerRow == destBytesPerRow {
            // Fast path for identical row layouts
            memcpy(destBase, srcBase, totalBytes)
        } else {
            // Copy row by row to handle different bytesPerRow (padding) between buffers
            let bytesToCopy = min(srcBytesPerRow, destBytesPerRow)
            for row in 0..<height {
                let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                let destRow = destBase.advanced(by: row * destBytesPerRow)
                memcpy(destRow, srcRow, bytesToCopy)
            }
        }

        return dest
    }

    private nonisolated func compositeFrame(
        screenBuffer: CVPixelBuffer,
        cameraBuffer: CVPixelBuffer?,
        context: CIContext,
        bufferPool: CVPixelBufferPool?,
        xNormalized: CGFloat,
        yNormalized: CGFloat,
        sizeFraction: CGFloat,
        shape: AppSettings.CameraOverlayShape,
        textOverlay: TextOverlay?
    ) -> CVPixelBuffer? {
        let screenImage = CIImage(cvPixelBuffer: screenBuffer)
        let screenWidth = CGFloat(CVPixelBufferGetWidth(screenBuffer))
        let screenHeight = CGFloat(CVPixelBufferGetHeight(screenBuffer))
        var composited = screenImage
        var didComposite = false

        if let cameraBuffer {
            guard let cameraOverlay = makeCameraOverlay(
                cameraBuffer: cameraBuffer,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                xNormalized: xNormalized,
                yNormalized: yNormalized,
                sizeFraction: sizeFraction,
                shape: shape
            ) else { return nil }
            composited = cameraOverlay.composited(over: composited)
            didComposite = true
        }

        if let textOverlay,
           let textImage = makeTextOverlayImage(
               text: textOverlay.text,
               screenWidth: screenWidth,
               screenHeight: screenHeight,
               position: textOverlay.position
           ) {
            composited = textImage.composited(over: composited)
            didComposite = true
        }

        guard didComposite else { return nil }

        guard let outputBuffer = makeOutputBuffer(
            width: Int(screenWidth),
            height: Int(screenHeight),
            bufferPool: bufferPool
        ) else { return nil }

        context.render(composited, to: outputBuffer)
        return outputBuffer
    }

    private nonisolated func makeCameraOverlay(
        cameraBuffer: CVPixelBuffer,
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        xNormalized: CGFloat,
        yNormalized: CGFloat,
        sizeFraction: CGFloat,
        shape: AppSettings.CameraOverlayShape
    ) -> CIImage? {
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

                guard let cachedOutput = radialGradient.outputImage?.cropped(
                    to: CGRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight)
                ) else { return nil }
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

        return cameraImage.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
    }

    private nonisolated func makeTextOverlayImage(
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
            guard let rendered = renderTextOverlay(text: text, fontSize: fontSize, maxWidth: screenWidth * 0.85) else {
                return nil
            }
            textOverlayCache.setObject(rendered, forKey: cacheKey as NSString)
            baseImage = rendered
        }

        let margin = max(24, min(screenWidth, screenHeight) * 0.04)
        let xOffset = (screenWidth - baseImage.extent.width) / 2
        let yOffset: CGFloat
        switch position {
        case .top:
            yOffset = screenHeight - baseImage.extent.height - margin
        case .center:
            yOffset = (screenHeight - baseImage.extent.height) / 2
        case .bottom:
            yOffset = margin
        }

        return baseImage.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
    }

    private nonisolated func renderTextOverlay(
        text: String,
        fontSize: CGFloat,
        maxWidth: CGFloat
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
        let constraint = CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraint,
            nil
        )
        let textWidth = ceil(min(maxWidth, max(1, suggestedSize.width)))
        let textHeight = ceil(max(fontSize * 1.25, suggestedSize.height))
        let horizontalPadding = ceil(fontSize * 0.6)
        let verticalPadding = ceil(fontSize * 0.35)
        let imageWidth = ceil(textWidth + horizontalPadding * 2)
        let imageHeight = ceil(textHeight + verticalPadding * 2)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmapContext = CGContext(
            data: nil,
            width: Int(imageWidth),
            height: Int(imageHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let backgroundRect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let backgroundPath = CGMutablePath()
        backgroundPath.addRoundedRect(
            in: backgroundRect,
            cornerWidth: fontSize * 0.3,
            cornerHeight: fontSize * 0.3
        )
        bitmapContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        bitmapContext.addPath(backgroundPath)
        bitmapContext.fillPath()

        let textRect = CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: textWidth,
            height: textHeight
        )
        let textPath = CGMutablePath()
        textPath.addRect(textRect)
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

    private nonisolated func makeOutputBuffer(
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
        autoreleasepool {
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
                guard !frameState.isCaptureStopped else { return }
                guard var writer = frameState.frameWriter else { return }
                guard !writer.hasWriteFailure else { return }

                cameraBuffer = frameState.latestCameraPixelBuffer

                if writer.startTime == nil {
                    writer.startTime = presentationTime
                    writer.assetWriter.startSession(atSourceTime: presentationTime)
                    frameState.frameWriter = writer
                }

                guard writer.videoInput.isReadyForMoreMediaData else { return }

                cameraX = frameState.currentCameraX
                cameraY = frameState.currentCameraY
                writerSnapshot = writer
            }

            guard let snapshot = writerSnapshot else { return }

            var frameToWrite = screenBuffer
            var usedCompositedBuffer = false

            let activeCameraBuffer = snapshot.recordCamera ? cameraBuffer : nil
            if activeCameraBuffer != nil || snapshot.textOverlay != nil {
                if let composited = compositeFrame(
                    screenBuffer: screenBuffer,
                    cameraBuffer: activeCameraBuffer,
                    context: snapshot.ciContext,
                    bufferPool: snapshot.bufferPool,
                    xNormalized: cameraX,
                    yNormalized: cameraY,
                    sizeFraction: snapshot.cameraSize,
                    shape: snapshot.cameraShape,
                    textOverlay: snapshot.textOverlay
                ) {
                    frameToWrite = composited
                    usedCompositedBuffer = true
                } else {
                    logger.warning("Frame compositing failed, using screen-only frame")
                }
            }

            withFrameLock {
                guard !frameState.isCaptureStopped else { return }
                guard var writer = frameState.frameWriter else { return }
                guard !writer.hasWriteFailure else { return }
                guard writer.videoInput.isReadyForMoreMediaData else { return }

                if !writer.adaptor.append(frameToWrite, withPresentationTime: presentationTime) {
                    let context = usedCompositedBuffer
                        ? "Failed to append composited video frame"
                        : "Failed to append video frame"
                    handleAppendFailure(&writer, context: context)
                    frameState.frameWriter = writer
                    frameState.isCaptureStopped = true
                    return
                }
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
        autoreleasepool {
            guard sampleBuffer.isValid else { return }

            if output is AVCaptureVideoDataOutput {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                // Copy the pixel buffer to ensure it remains valid after callback returns
                guard let copiedBuffer = copyPixelBuffer(pixelBuffer) else { return }
                let stored = withFrameLock { () -> Bool in
                    guard !frameState.isCaptureStopped else { return false }
                    frameState.latestCameraPixelBuffer = copiedBuffer
                    return true
                }
                guard stored else { return }
            } else if output is AVCaptureAudioDataOutput {
                let writer = withFrameLock { () -> FrameWriter? in
                    guard !frameState.isCaptureStopped else { return nil }
                    return frameState.frameWriter
                }

                guard var writer,
                      writer.startTime != nil,
                      let audio = writer.audioInput,
                      audio.isReadyForMoreMediaData
                else { return }

                if !audio.append(sampleBuffer) {
                    withFrameLock {
                        handleAppendFailure(&writer, context: "Failed to append audio sample")
                        frameState.frameWriter = writer
                        frameState.isCaptureStopped = true
                    }
                }
            }
        }
    }
}
