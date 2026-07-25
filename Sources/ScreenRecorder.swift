@preconcurrency import AVFoundation
import CoreImage
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

enum RecordingFileNaming {
    static func sanitizedTimestamp(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }

    static func fileName(date: Date, randomID: String) -> String {
        "Reel-\(sanitizedTimestamp(from: date))-\(randomID).mp4"
    }
}

enum RecordingDiskSpace {
    /// A recording is refused unless the destination volume can hold at least
    /// this many minutes at the configured bitrate. This is a floor, not a
    /// guarantee: long takes are protected separately, while running.
    static let minimumMinutes: Double = 2

    /// Video bitrate converted to bytes, plus headroom for the AAC audio
    /// track and container overhead.
    static func bytesPerSecond(bitrate: Int) -> Int64 {
        Int64(Double(bitrate) / 8 * 1.1)
    }

    static func requiredBytes(bitrate: Int) -> Int64 {
        bytesPerSecond(bitrate: bitrate) * Int64(minimumMinutes * 60)
    }

    static func recordableSeconds(availableBytes: Int64, bitrate: Int) -> Double {
        let perSecond = bytesPerSecond(bitrate: bitrate)
        guard perSecond > 0 else { return .infinity }
        return Double(max(0, availableBytes)) / Double(perSecond)
    }

    /// How often a running recording re-checks the destination volume.
    static let checkInterval: TimeInterval = 10

    /// A running recording ends once free space drops below this many seconds
    /// of capture — early enough that the writer can still be finalized into a
    /// playable file.
    static let stopSeconds: Double = 30

    static func isCriticallyLow(availableBytes: Int64, bitrate: Int) -> Bool {
        recordableSeconds(availableBytes: availableBytes, bitrate: bitrate) < stopSeconds
    }

    static func lowSpaceReason(availableBytes: Int64) -> String {
        let free = ByteCountFormatter.string(
            fromByteCount: max(0, availableBytes),
            countStyle: .file
        )
        return "the disk is almost full (\(free) left)"
    }

    /// Non-nil when the destination volume cannot hold a usable recording.
    static func shortfallMessage(availableBytes: Int64, bitrate: Int, directory: URL) -> String? {
        guard availableBytes < requiredBytes(bitrate: bitrate) else { return nil }

        let free = ByteCountFormatter.string(
            fromByteCount: max(0, availableBytes),
            countStyle: .file
        )
        let seconds = Int(recordableSeconds(availableBytes: availableBytes, bitrate: bitrate))
        return """
            Not enough free space in \(directory.path()) to record. \
            \(free) available, about \(seconds)s at the current video quality. \
            Free up space or lower the video quality in Settings.
            """
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

struct TextOverlay {
    let text: String
    let position: AppSettings.TextOverlayPosition
}

/// Everything a recording needs from settings, snapshotted the moment it
/// starts. A take is then immune to settings edited while it runs, and the
/// recorder reads live settings only where it genuinely has to write back.
struct RecordingOptions {
    var frameRate: Int
    var showCursor: Bool
    var videoBitrate: Int
    var outputDirectory: URL
    var askWhereToSave: Bool
    var openFinderAfterRecording: Bool
    var showPreviewAfterRecording: Bool

    var recordAudio: Bool
    var audioSource: AppSettings.AudioSource
    var audioDevice: AVCaptureDevice?

    var recordCamera: Bool
    var cameraDevice: AVCaptureDevice?
    var cameraShape: AppSettings.CameraOverlayShape
    var cameraPosition: AppSettings.CameraOverlayPosition
    var cameraSizeFraction: CGFloat

    var textOverlay: TextOverlay?

    /// Front cameras are mirrored in the on-screen preview, so the composited
    /// output has to be mirrored too or the recording will not match what the
    /// user was looking at.
    var mirrorCamera: Bool {
        recordCamera && cameraDevice?.position == .front
    }

    @MainActor
    init(settings: AppSettings) {
        frameRate = settings.frameRate
        showCursor = settings.showCursor
        videoBitrate = settings.videoQuality.bitrate
        outputDirectory = settings.outputDirectory
        askWhereToSave = settings.askWhereToSave
        openFinderAfterRecording = settings.openFinderAfterRecording
        showPreviewAfterRecording = settings.showPreviewAfterRecording

        recordAudio = settings.recordAudio
        audioSource = settings.audioSource
        audioDevice = settings.recordAudio ? settings.selectedAudioDevice : nil

        recordCamera = settings.recordCamera
        cameraDevice = settings.recordCamera ? settings.selectedCamera : nil
        cameraShape = settings.cameraShape
        cameraPosition = settings.cameraPosition
        cameraSizeFraction = settings.cameraSizeFraction

        textOverlay = settings.activeTextOverlayText.map {
            TextOverlay(text: $0, position: settings.textOverlayPosition)
        }
    }
}

private struct FrameWriter {
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let assetWriter: AVAssetWriter
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
            guard oldValue != isRecording else { return }
            onRecordingStateChanged?(isRecording)
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

    /// Invoked when recording starts or stops. The recorder drives status item
    /// artwork, the elapsed timer, and the on-screen overlays this way rather
    /// than reaching into the app delegate itself.
    var onRecordingStateChanged: ((Bool) -> Void)?

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
    /// Settings snapshot for the recording currently in flight.
    private var activeOptions: RecordingOptions?
    private var lowSpaceTimer: Timer?
    private let captureSessionQueue = DispatchQueue(label: "com.rselbach.reel.capture")
    // Reused across recordings; a CIContext is cheap to hold but expensive to
    // recreate per recording.
    private nonisolated let compositor = FrameCompositor(ciContext: CIContext())
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

    /// The settings snapshot driving the recording in flight. The on-screen
    /// camera overlay reads this rather than live settings so what the user
    /// drags matches what is being composited into the file.
    var activeRecordingOptions: RecordingOptions? { activeOptions }
    
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

        // Snapshot settings once so nothing edited mid-take can change the
        // recording that is already running.
        let options = RecordingOptions(settings: settings)
        activeOptions = options

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

        // A writer that fails mid-recording cannot be finalized, so a full
        // disk destroys the whole take. Refuse up front instead.
        if let shortfall = diskSpaceShortfall(options: options) {
            errorMessage = shortfall
            return
        }

        do {
            let config = SCStreamConfiguration()
            config.width = captureWidth
            config.height = captureHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
            config.queueDepth = 5
            config.showsCursor = options.showCursor
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
            if options.recordAudio, options.audioSource == .microphone {
                guard await ensureAVPermission(for: .audio) else {
                    errorMessage = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
                    return
                }
            }

            if options.recordCamera {
                guard await ensureAVPermission(for: .video) else {
                    errorMessage = "Camera access denied. Enable it in System Settings → Privacy & Security → Camera."
                    return
                }
            }

            // Set up capture sessions before the asset writer so the audio
            // input can use the source's recommended settings (makeAudioInput).
            if options.recordAudio {
                switch options.audioSource {
                case .microphone:
                    try setupAudioCapture(options: options)
                case .systemAudio:
                    configureSystemAudioCapture(config)
                }
            }

            if options.recordCamera {
                try setupCameraCapture(options: options)
            }

            try setupAssetWriter(width: config.width, height: config.height, options: options)

            stream = SCStream(filter: filter, configuration: config, delegate: self)

            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamOutputQueue)
            if config.capturesAudio {
                try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
            }

            try await stream?.startCapture()
            let failures = startCaptureSessions()
            lastRecordedURL = nil
            isRecording = true
            startLowSpaceMonitor()

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

    private func setupAssetWriter(width: Int, height: Int, options: RecordingOptions) throws {
        let outputURL = try makeOutputURL(options: options)
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = makeVideoInput(width: width, height: height, bitrate: options.videoBitrate)

        guard assetWriter.canAdd(videoInput) else {
            throw NSError(domain: "ScreenRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }

        assetWriter.add(videoInput)

        let adaptor = makePixelBufferAdaptor(videoInput: videoInput, width: width, height: height)
        let bufferPool = makeBufferPool(width: width, height: height)
        let audioInput = options.recordAudio ? makeAudioInput(assetWriter: assetWriter) : nil

        updateFrameWriter(
            adaptor: adaptor,
            videoInput: videoInput,
            audioInput: audioInput,
            assetWriter: assetWriter,
            bufferPool: bufferPool,
            options: options
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

    private func diskSpaceShortfall(options: RecordingOptions) -> String? {
        let directory = options.outputDirectory
        guard let available = Self.availableCapacity(at: directory) else { return nil }
        return RecordingDiskSpace.shortfallMessage(
            availableBytes: available,
            bitrate: options.videoBitrate,
            directory: directory
        )
    }

    /// Free space the system is willing to give up for important user data.
    /// Returns nil when the volume cannot be queried (a missing directory,
    /// most often), in which case the recording is allowed to proceed.
    private static func availableCapacity(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            logger.warning("Could not read free space for \(url.path()): \(error.localizedDescription)")
            return nil
        }
    }

    private func makeOutputURL(options: RecordingOptions) throws -> URL {
        let outputDir = options.outputDirectory
        do {
            return try makeOutputURL(in: outputDir)
        } catch {
            logger.warning("Configured output directory unavailable (\(outputDir.path()), using fallback: \(error.localizedDescription))")
            let fallback = AppSettings.defaultOutputDirectory()
            persistSettingOutputDirectory(fallback)
            // Keep the in-flight snapshot pointing at the directory actually
            // being written to, so the save panel and space checks agree.
            activeOptions?.outputDirectory = fallback
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

    private func makeVideoInput(width: Int, height: Int, bitrate: Int) -> AVAssetWriterInput {
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
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
        bufferPool: CVPixelBufferPool?,
        options: RecordingOptions
    ) {
        let initialPos = options.cameraPosition.normalizedCoordinates
        withFrameLock {
            frameState.currentCameraX = initialPos.x
            frameState.currentCameraY = initialPos.y
            frameState.currentCameraSizeFraction = options.cameraSizeFraction
            frameState.frameWriter = FrameWriter(
                adaptor: adaptor,
                videoInput: videoInput,
                audioInput: audioInput,
                assetWriter: assetWriter,
                bufferPool: bufferPool,
                startTime: nil,
                recordCamera: options.recordCamera,
                cameraShape: options.cameraShape,
                mirrorCamera: options.mirrorCamera,
                textOverlay: options.textOverlay
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

    private func setupAudioCapture(options: RecordingOptions) throws {
        guard let device = options.audioDevice else {
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

    private func setupCameraCapture(options: RecordingOptions) throws {
        guard let device = options.cameraDevice else {
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
        // Always the snapshot taken at start: the user may have changed where
        // recordings go while this one was running.
        let options = activeOptions ?? RecordingOptions(settings: settings)

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

        if options.askWhereToSave {
            // As a menu bar (accessory) app there is usually no key window
            // when a recording stops; without activation the save panel can
            // open behind the frontmost app.
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = tempURL.lastPathComponent
            panel.directoryURL = options.outputDirectory

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
            openFinderAfterRecording: options.openFinderAfterRecording,
            showPreviewAfterRecording: options.showPreviewAfterRecording
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
        stopLowSpaceMonitor()
        stream = nil
        outputURL = nil
        activeOptions = nil
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        audioCaptureSession = nil
        audioOutput = nil
        audioOutputSettings = nil
        cameraCaptureSession = nil
        cameraOutput = nil
        compositor.reset()
        withFrameLock {
            frameState.latestCameraPixelBuffer = nil
            frameState.frameWriter = nil
        }
    }

    /// Ends the recording after the stream stopped on its own (recorded window
    /// closed, display disconnected, screen locked).
    private func handleStreamStopped(dueTo error: Error) async {
        await endRecordingUnexpectedly(
            savedMessage: "Recording stopped unexpectedly (\(error.localizedDescription)). The partial recording was saved.",
            discardedMessage: "Recording stopped before any frames were captured: \(error.localizedDescription)",
            stoppingStream: false
        )
    }

    /// Ends a recording that the user did not stop. Frames already written are
    /// finalized into a playable file; the recording is only discarded when
    /// nothing was captured yet.
    /// - Parameter stoppingStream: true when the stream is still running and
    ///   has to be told to stop, false when it already stopped on its own.
    private func endRecordingUnexpectedly(
        savedMessage: String,
        discardedMessage: String,
        stoppingStream: Bool
    ) async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { finishStopping() }

        signalCaptureStop()
        stopCaptureSessions()

        if stoppingStream {
            do {
                try await stream?.stopCapture()
            } catch {
                logger.warning("Failed to stop capture during automatic stop: \(error.localizedDescription)")
            }
        }

        let hasCapturedFrames = withFrameLock { frameState.frameWriter?.startTime != nil }
        if hasCapturedFrames {
            await finalizeRecording()
            if lastRecordedURL != nil {
                errorMessage = savedMessage
            }
        } else {
            assetWriter?.cancelWriting()
            if let outputURL {
                discardTempRecording(outputURL)
            }
            errorMessage = discardedMessage
        }

        cleanup()
        isRecording = false
        onUnexpectedStop?()
    }

    /// Polls the destination volume while recording and ends the take before
    /// the writer runs out of room. A writer that fails cannot be finalized,
    /// so stopping early is the only way to keep what has been captured.
    private func startLowSpaceMonitor() {
        stopLowSpaceMonitor()
        let timer = Timer(
            timeInterval: RecordingDiskSpace.checkInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.stopIfSpaceCriticallyLow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lowSpaceTimer = timer
    }

    private func stopLowSpaceMonitor() {
        lowSpaceTimer?.invalidate()
        lowSpaceTimer = nil
    }

    private func stopIfSpaceCriticallyLow() async {
        guard isRecording, !isStopping else { return }

        let options = activeOptions ?? RecordingOptions(settings: settings)
        let directory = outputURL?.deletingLastPathComponent() ?? options.outputDirectory
        guard let available = Self.availableCapacity(at: directory),
              RecordingDiskSpace.isCriticallyLow(
                  availableBytes: available,
                  bitrate: options.videoBitrate
              ) else {
            return
        }

        let reason = RecordingDiskSpace.lowSpaceReason(availableBytes: available)
        logger.warning("Stopping recording early: \(reason, privacy: .public)")
        await endRecordingUnexpectedly(
            savedMessage: "Recording stopped because \(reason). What was captured so far was saved.",
            discardedMessage: "Recording stopped before any frames were captured because \(reason)",
            stoppingStream: true
        )
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

            let cameraOverlay = (snapshot.recordCamera ? cameraBuffer : nil).map { buffer in
                FrameCompositor.CameraOverlay(
                    buffer: buffer,
                    x: cameraX,
                    y: cameraY,
                    sizeFraction: cameraSizeFraction,
                    shape: snapshot.cameraShape,
                    mirrored: snapshot.mirrorCamera
                )
            }
            if cameraOverlay != nil || snapshot.textOverlay != nil {
                if let composited = compositor.composite(
                    screenBuffer: screenBuffer,
                    camera: cameraOverlay,
                    text: snapshot.textOverlay,
                    bufferPool: snapshot.bufferPool
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
