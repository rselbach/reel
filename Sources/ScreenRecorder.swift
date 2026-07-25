@preconcurrency import AVFoundation
import CoreImage
import CoreText
import os.log
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "ScreenRecorder")

enum RecordingMode {
    case display
    case window
    case region
}

private enum RecordingConstants {
    /// Minimum dimensions for windows to appear in the picker (filters tiny/hidden windows)
    static let minimumWindowSize: CGFloat = 100
    /// Conservative H.264 dimensions for broad AVAssetWriter compatibility.
    static let maxH264Size = CGSize(width: 4096, height: 2304)
}

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

enum RecordingFileNaming {
    static func sanitizedTimestamp(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }

    static func fileName(date: Date, randomID: String) -> String {
        "Reel-\(sanitizedTimestamp(from: date))-\(randomID).mp4"
    }
}

enum RecordingFinalizationLogic {
    static func shouldRevealInFinder(openFinderAfterRecording: Bool, showPreviewAfterRecording: Bool) -> Bool {
        openFinderAfterRecording && !showPreviewAfterRecording
    }

    static func finderRevealFailureMessage(for url: URL) -> String {
        "Recording saved, but Finder could not reveal it: \(url.path())"
    }
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

private struct FrameWriter {
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let assetWriter: AVAssetWriter
    let ciContext: CIContext
    let bufferPool: CVPixelBufferPool?
    var startTime: CMTime?
    let recordCamera: Bool
    let cameraShape: AppSettings.CameraOverlayShape
    // Front cameras are mirrored in the on-screen preview; mirror the
    // composited output too so the recording matches what the user saw.
    let mirrorCamera: Bool
    let textOverlay: TextOverlay?
    var hasWriteFailure = false
}

private final class FrameCaptureState {
    var latestCameraPixelBuffer: CVPixelBuffer?
    var frameWriter: FrameWriter?
    var isCaptureStopped = false
    var currentCameraX: CGFloat = 1.0
    var currentCameraY: CGFloat = 0.0
    var currentCameraSizeFraction: CGFloat = 0.2
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
    private(set) var isStarting = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    @Published var hasPermission = false
    @Published var availableDisplays: [SCDisplay] = []
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindow: SCWindow?
    @Published var selectedRegion: RecordingRegion?
    @Published var recordingMode: RecordingMode = .display
    @Published var errorMessage: String?
    @Published var lastRecordedURL: URL?

    /// Invoked when a recording ends without the user asking it to (stream
    /// error or writer failure), after errorMessage and lastRecordedURL are
    /// updated. Lets the app surface the failure instead of burying it in the
    /// menu.
    var onUnexpectedStop: (() -> Void)?

    var countdownTargetFrame: CGRect? {
        switch recordingMode {
        case .display:
            return selectedDisplay?.frame
        case .window:
            return selectedWindow?.frame
        case .region:
            guard let region = selectedRegion,
                  let display = regionDisplay(for: region) else { return nil }
            return RegionMath.globalQuartzFrame(regionRect: region.rect, displayFrame: display.frame)
        }
    }

    private func regionDisplay(for region: RecordingRegion) -> SCDisplay? {
        availableDisplays.first { $0.displayID == region.displayID }
    }

    private var selectedDisplay: SCDisplay? {
        guard let selectedDisplayID else { return nil }
        return availableDisplays.first { $0.displayID == selectedDisplayID }
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
    // Separate serial queue for SCStream system-audio samples so audio
    // delivery is never blocked behind frame compositing.
    private let systemAudioQueue = DispatchQueue(label: "com.rselbach.reel.system-audio")

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

    /// Re-validates the last recording selection before a hotkey-initiated
    /// start. Returns false when the selection no longer exists (window
    /// closed, display removed) so the caller can show the picker instead of
    /// silently failing or recording the wrong thing. For window mode the
    /// stored SCWindow is replaced with a fresh instance so its frame is
    /// current.
    func validateSelectionForQuickStart() async -> Bool {
        await refreshWindows()
        switch recordingMode {
        case .display:
            return selectedDisplay != nil
        case .window:
            guard let windowID = selectedWindow?.windowID,
                  let fresh = availableWindows.first(where: { $0.windowID == windowID }) else {
                return false
            }
            selectedWindow = fresh
            return true
        case .region:
            guard let region = selectedRegion,
                  let display = regionDisplay(for: region) else { return false }
            let displayBounds = CGRect(origin: .zero, size: display.frame.size)
            return displayBounds.contains(region.rect)
        }
    }

    private func updateShareableContent(updatePermissionState: Bool, failureMessage: String) async {
        do {
            let content = try await loadShareableContent()
            availableDisplays = content.displays
            availableWindows = content.windows
            if selectedDisplayID == nil {
                selectedDisplayID = content.displays.first?.displayID
            }
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
        return Self.dimensionsFittingH264Limits(
            width: Int(CGFloat(display.width) * scale),
            height: Int(CGFloat(display.height) * scale)
        )
    }

    private func captureDimensions(for window: SCWindow) -> (width: Int, height: Int) {
        let windowScreen = cocoaRect(fromQuartz: window.frame).flatMap { windowFrame in
            NSScreen.screens
                .map { screen in (screen, screen.frame.intersection(windowFrame)) }
                .filter { !$0.1.isNull && !$0.1.isEmpty }
                .max { lhs, rhs in
                    lhs.1.width * lhs.1.height < rhs.1.width * rhs.1.height
                }?
                .0
        }
        let scale = windowScreen?.backingScaleFactor ?? 2.0
        return Self.dimensionsFittingH264Limits(
            width: Int(window.frame.width * scale),
            height: Int(window.frame.height * scale)
        )
    }

    private func captureDimensions(forRegion rect: CGRect, on display: SCDisplay) -> (width: Int, height: Int) {
        let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2.0
        return Self.dimensionsFittingH264Limits(
            width: Int(rect.width * scale),
            height: Int(rect.height * scale)
        )
    }

    static func dimensionsFittingH264Limits(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }

        let scale = min(
            1,
            min(
                RecordingConstants.maxH264Size.width / CGFloat(width),
                RecordingConstants.maxH264Size.height / CGFloat(height)
            )
        )
        let scaledWidth = max(2, Int((CGFloat(width) * scale).rounded(.down)))
        let scaledHeight = max(2, Int((CGFloat(height) * scale).rounded(.down)))

        return (
            width: scaledWidth - (scaledWidth % 2),
            height: scaledHeight - (scaledHeight % 2)
        )
    }

    func startRecording() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { finishStarting() }

        // Reset stop signal for new recording
        resetCaptureStopSignal()

        let filter: SCContentFilter
        let captureWidth: Int
        let captureHeight: Int

        switch recordingMode {
        case .display:
            guard let display = selectedDisplay else {
                errorMessage = "No display selected"
                return
            }
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

        case .region:
            guard let region = selectedRegion,
                  let display = regionDisplay(for: region) else {
                errorMessage = "No region selected"
                return
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            let dimensions = captureDimensions(forRegion: region.rect, on: display)
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

            // Crop the display capture down to the selected region (points,
            // display-local top-left origin — the space sourceRect expects).
            if recordingMode == .region, let region = selectedRegion {
                config.sourceRect = region.rect
            }

            // Request AVFoundation permissions before allocating any recording
            // resources, so a denial surfaces a clear message instead of a
            // generic "Failed to start" and leaves no temp file behind.
            // System audio rides on the screen recording permission instead.
            if settings.recordAudio, settings.audioSource == .microphone {
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
                switch settings.audioSource {
                case .microphone:
                    try setupAudioCapture()
                case .systemAudio:
                    configureSystemAudioCapture(config)
                }
            }

            if settings.recordCamera {
                try setupCameraCapture()
            }

            try setupAssetWriter(width: config.width, height: config.height)

            stream = SCStream(filter: filter, configuration: config, delegate: self)

            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamOutputQueue)
            if config.capturesAudio {
                try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
            }

            try await stream?.startCapture()
            let failures = startCaptureSessions()
            lastRecordedURL = nil
            isRecording = true

            // Surface capture session failures as warnings (recording continues without them)
            if failures.cameraFailed {
                disableCameraCaptureAfterStartFailure()
            }
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
            if let assetWriter, assetWriter.status == .writing {
                assetWriter.cancelWriting()
            }
            if let outputURL {
                discardTempRecording(outputURL)
            }
            cleanup()
        }
    }

    @discardableResult
    func stopRecording() async -> Bool {
        if isStarting {
            await waitForActiveStart()
        }
        guard isRecording else { return false }
        if isStopping {
            await waitForActiveStop()
            return false
        }
        isStopping = true
        defer { finishStopping() }

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
        return true
    }

    private func waitForActiveStart() async {
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func finishStarting() {
        isStarting = false
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForActiveStop() async {
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    private func finishStopping() {
        isStopping = false
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
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

    /// Updates the camera overlay size the compositor uses while a recording
    /// is in flight. Persisting the new size is a separate step the overlay
    /// window triggers once a corner drag ends, so the size carries over to
    /// the next recording.
    /// - Parameter fraction: Overlay width as a fraction of the recording width.
    func updateCameraOverlaySize(fraction: CGFloat) {
        withFrameLock {
            frameState.currentCameraSizeFraction = min(
                max(fraction, CameraOverlayResizeLogic.minFraction),
                CameraOverlayResizeLogic.maxFraction
            )
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

        let date = Date()
        for _ in 0..<64 {
            let randomID = String(UUID().uuidString.prefix(8))
            let candidate = outputDir.appendingPathComponent(
                RecordingFileNaming.fileName(date: date, randomID: randomID)
            )
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
        let mirrorCamera = settings.recordCamera && settings.selectedCamera?.position == .front
        withFrameLock {
            frameState.currentCameraX = initialPos.x
            frameState.currentCameraY = initialPos.y
            frameState.currentCameraSizeFraction = settings.cameraSizeFraction
            frameState.frameWriter = FrameWriter(
                adaptor: adaptor,
                videoInput: videoInput,
                audioInput: audioInput,
                assetWriter: assetWriter,
                ciContext: context,
                bufferPool: bufferPool,
                startTime: nil,
                recordCamera: settings.recordCamera,
                cameraShape: settings.cameraShape,
                mirrorCamera: mirrorCamera,
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

    /// Captures the system's audio output through the SCStream itself; no
    /// extra permission is needed beyond screen recording. Our own audio is
    /// excluded so alert sounds from Reel don't end up in recordings.
    private func configureSystemAudioCapture(_ config: SCStreamConfiguration) {
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        audioOutputSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
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
        var replacementWarning: FileReplacementWarning?

        if settings.askWhereToSave {
            // As a menu bar (accessory) app there is usually no key window
            // when a recording stops; without activation the save panel can
            // open behind the frontmost app.
            NSApp.activate(ignoringOtherApps: true)
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
            guard response == .OK, let url = panel.url else {
                logger.info("Save cancelled; discarding temporary recording")
                discardTempRecording(tempURL)
                lastRecordedURL = nil
                errorMessage = nil
                return
            }

            finalURL = url
            do {
                replacementWarning = try moveTempRecording(from: tempURL, to: finalURL)
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
                discardTempRecording(tempURL)
                return
            }
        }

        logger.info("Recording saved to: \(finalURL.path())")
        lastRecordedURL = finalURL
        settings.noteRecentRecording(finalURL)
        if let replacementWarning {
            let warning = replacementWarning.localizedDescription
            errorMessage = errorMessage.map { "\($0)\n\(warning)" } ?? warning
        }

        if RecordingFinalizationLogic.shouldRevealInFinder(
            openFinderAfterRecording: settings.openFinderAfterRecording,
            showPreviewAfterRecording: settings.showPreviewAfterRecording
        ) {
            let revealed = NSWorkspace.shared.selectFile(finalURL.path(), inFileViewerRootedAtPath: "")
            if !revealed {
                let revealError = RecordingFinalizationLogic.finderRevealFailureMessage(for: finalURL)
                errorMessage = errorMessage.map { "\($0)\n\(revealError)" } ?? revealError
            }
        }
    }

    private func moveTempRecording(
        from tempURL: URL,
        to finalURL: URL
    ) throws -> FileReplacementWarning? {
        if finalURL == tempURL {
            logger.info("Recording already at final location, skipping move")
            return nil
        }

        return try FileReplacement.commit(tempURL: tempURL, to: finalURL)
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
        outputURL = nil
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

    /// Ends the recording after the stream stopped on its own (recorded window
    /// closed, display disconnected, screen locked). Frames already written are
    /// finalized into a playable file; the recording is only discarded when
    /// nothing was captured yet.
    private func handleStreamStopped(dueTo error: Error) async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { finishStopping() }

        signalCaptureStop()
        stopCaptureSessions()

        let hasCapturedFrames = withFrameLock { frameState.frameWriter?.startTime != nil }
        if hasCapturedFrames {
            await finalizeRecording()
            if lastRecordedURL != nil {
                errorMessage = "Recording stopped unexpectedly (\(error.localizedDescription)). The partial recording was saved."
            }
        } else {
            assetWriter?.cancelWriting()
            if let outputURL {
                discardTempRecording(outputURL)
            }
            errorMessage = "Recording stopped before any frames were captured: \(error.localizedDescription)"
        }

        cleanup()
        isRecording = false
        onUnexpectedStop?()
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

    private func disableCameraCaptureAfterStartFailure() {
        let cameraSession = cameraCaptureSession
        captureSessionQueue.sync {
            cameraSession?.stopRunning()
        }
        cameraCaptureSession = nil
        cameraOutput = nil
        withFrameLock {
            frameState.latestCameraPixelBuffer = nil
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
        mirrored: Bool,
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
                shape: shape,
                mirrored: mirrored
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

    /// Builds the camera bubble exactly as the draggable preview window shows
    /// it: a square, aspect-fill center crop (mirrored for front cameras)
    /// whose position maps over the full recording bounds with no extra
    /// padding, so what the user drags on screen is what lands in the file.
    private nonisolated func makeCameraOverlay(
        cameraBuffer: CVPixelBuffer,
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        xNormalized: CGFloat,
        yNormalized: CGFloat,
        sizeFraction: CGFloat,
        shape: AppSettings.CameraOverlayShape,
        mirrored: Bool
    ) -> CIImage? {
        var cameraImage = CIImage(cvPixelBuffer: cameraBuffer)
        let cameraWidth = CGFloat(CVPixelBufferGetWidth(cameraBuffer))
        let cameraHeight = CGFloat(CVPixelBufferGetHeight(cameraBuffer))
        let overlaySize = CameraOverlayLayout.overlaySize(
            sizeFraction: sizeFraction,
            bounds: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight)
        ).rounded()
        guard overlaySize > 0, cameraWidth > 0, cameraHeight > 0 else { return nil }

        if mirrored {
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

        if shape == .circle {
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
            x: xNormalized,
            y: yNormalized,
            overlaySize: overlaySize,
            bounds: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight)
        )

        return cameraImage.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
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

    private nonisolated func renderTextOverlay(
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
            await stopAfterWriteFailure(context: context, reason: reason)
        }
    }

    /// Tears down a recording whose asset writer can no longer accept samples.
    /// A failed writer cannot be finalized, so the file is discarded and the
    /// session ended instead of silently dropping every subsequent frame while
    /// the UI still claims to be recording.
    private func stopAfterWriteFailure(context: String, reason: String) async {
        guard isRecording, !isStopping else {
            errorMessage = "\(context): \(reason)"
            return
        }
        isStopping = true
        defer { finishStopping() }

        signalCaptureStop()
        stopCaptureSessions()
        do {
            try await stream?.stopCapture()
        } catch {
            logger.warning("Failed to stop capture after write failure: \(error.localizedDescription)")
        }
        assetWriter?.cancelWriting()
        if let outputURL {
            discardTempRecording(outputURL)
        }
        cleanup()
        isRecording = false
        errorMessage = "\(context): \(reason)"
        onUnexpectedStop?()
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            await handleStreamStopped(dueTo: error)
        }
    }
}

extension ScreenRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            handleScreenSampleBuffer(sampleBuffer)
        case .audio:
            autoreleasepool {
                guard sampleBuffer.isValid else { return }
                appendAudioSampleBuffer(sampleBuffer)
            }
        default:
            return
        }
    }

    private nonisolated func handleScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        autoreleasepool {
            guard sampleBuffer.isValid,
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
            var cameraSizeFraction: CGFloat = 0.2

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
                cameraSizeFraction = frameState.currentCameraSizeFraction
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
                    sizeFraction: cameraSizeFraction,
                    shape: snapshot.cameraShape,
                    mirrored: snapshot.mirrorCamera,
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
                appendAudioSampleBuffer(sampleBuffer)
            }
        }
    }

    /// Appends an audio sample (microphone or system audio) to the writer.
    /// Samples arriving before the video session starts are dropped so audio
    /// never leads the first frame.
    private nonisolated func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
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
