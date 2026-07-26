@preconcurrency import AVFoundation
import CoreImage
import os.log
import ScreenCaptureKit
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "ScreenRecorder")

enum RecordingMode {
    case display
    case window
    case region
}

private enum RecordingConstants {
    /// Minimum dimensions for windows to appear in the picker (filters tiny/hidden windows)
    static let minimumWindowSize: CGFloat = 100
}

enum RecordingFinalizationLogic {
    static func destination(tempURL: URL, requestedURL: URL?) -> URL {
        requestedURL ?? tempURL
    }

    static func shouldRevealInFinder(openFinderAfterRecording: Bool, showPreviewAfterRecording: Bool) -> Bool {
        openFinderAfterRecording && !showPreviewAfterRecording
    }

    static func finderRevealFailureMessage(for url: URL) -> String {
        "Recording saved, but Finder could not reveal it: \(url.path())"
    }

    static func retainedRecordingMessage(for url: URL, saveError: Error) -> String {
        "Could not save to the chosen location. The recording was kept at \(url.path()): \(saveError.localizedDescription)"
    }
}

/// Per-recording changes to the persisted settings, chosen in the picker and
/// applied to one take only.
struct RecordingOverrides: Equatable {
    var recordAudio: Bool?
    var recordCamera: Bool?

    static let none = RecordingOverrides()

    var isEmpty: Bool { self == .none }
}

/// What the app needs to put in front of the user to pick a destination.
struct SaveDestinationRequest {
    let suggestedName: String
    let directory: URL
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
    /// Output height cap in pixels, or nil to keep the captured size.
    var resolutionMaxHeight: CGFloat?
    var videoCodec: AppSettings.VideoCodec
    var highlightClicks: Bool
    var frameWindowRecordings: Bool
    var windowBackground: FrameCompositor.BackgroundFill
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
    init(settings: AppSettings, overrides: RecordingOverrides = .none) {
        frameRate = settings.frameRate
        showCursor = settings.showCursor
        videoBitrate = settings.videoQuality.bitrate
        resolutionMaxHeight = settings.videoResolution.maxHeight
        videoCodec = settings.videoCodec
        highlightClicks = settings.highlightClicks
        frameWindowRecordings = settings.frameWindowRecordings
        windowBackground = settings.windowBackground.fill
        outputDirectory = settings.outputDirectory
        askWhereToSave = settings.askWhereToSave
        openFinderAfterRecording = settings.openFinderAfterRecording
        showPreviewAfterRecording = settings.showPreviewAfterRecording

        let wantsAudio = overrides.recordAudio ?? settings.recordAudio
        let wantsCamera = overrides.recordCamera ?? settings.recordCamera

        recordAudio = wantsAudio
        audioSource = settings.audioSource
        audioDevice = wantsAudio ? settings.selectedAudioDevice : nil

        recordCamera = wantsCamera
        cameraDevice = wantsCamera ? settings.selectedCamera : nil
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
    let highlightClicks: Bool
    /// Non-nil when the captured window is drawn inset on a background.
    let windowFrame: FrameCompositor.WindowFrame?
    var hasWriteFailure = false
    /// Total time spent paused so far. Subtracted from every sample's
    /// timestamp so the output has no gap where the pauses were.
    var pausedDuration: CMTime = .zero
    /// Presentation time of the first frame seen during the current pause.
    var pauseStartTime: CMTime?
}

private final class FrameCaptureState {
    var latestCameraPixelBuffer: CVPixelBuffer?
    var frameWriter: FrameWriter?
    var isCaptureStopped = false
    var currentCameraX: CGFloat = 1.0
    var currentCameraY: CGFloat = 0.0
    var currentCameraSizeFraction: CGFloat = 0.2
    var isPaused = false
    /// Pointer position in captured-frame pixel coordinates, sampled on the
    /// main actor; nil when the pointer is outside the captured bounds or no
    /// button is down.
    var pressedCursorPoint: CGPoint?
}

@MainActor
class ScreenRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            onRecordingStateChanged?(isRecording)
        }
    }
    /// Paused recordings keep the stream and capture sessions running but
    /// write nothing, and the time spent paused is removed from the output.
    @Published private(set) var isPaused = false {
        didSet {
            guard oldValue != isPaused else { return }
            onPauseStateChanged?(isPaused)
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

    /// Invoked when a running recording is paused or resumed.
    var onPauseStateChanged: ((Bool) -> Void)?

    /// Asks where to put a finished recording when the user chose "Ask each
    /// time". Returning nil keeps it at its default location. The recorder
    /// owns the temporary file's lifetime but never presents UI itself.
    var requestSaveDestination: (@MainActor (SaveDestinationRequest) async -> URL?)?

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

    /// Re-applies the target remembered from a previous launch. Must run after
    /// shareable content has loaded, since the display, window, or region has
    /// to still exist before it can be selected. Anything that has gone away
    /// leaves the current selection alone.
    func restoreRememberedTarget() {
        guard let target = settings.rememberedTarget else { return }

        switch target {
        case .display(let displayID):
            guard availableDisplays.contains(where: { $0.displayID == displayID }) else { return }
            selectedDisplayID = displayID
            recordingMode = .display

        case .window(let bundleID, let title):
            guard let index = RememberedTargetMatching.bestMatchIndex(
                bundleIDs: availableWindows.map { $0.owningApplication?.bundleIdentifier },
                titles: availableWindows.map { $0.title },
                wantedBundleID: bundleID,
                wantedTitle: title
            ) else { return }
            selectedWindow = availableWindows[index]
            recordingMode = .window

        case .region(let displayID, let x, let y, let width, let height):
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard let display = availableDisplays.first(where: { $0.displayID == displayID }),
                  CGRect(origin: .zero, size: display.frame.size).contains(rect) else {
                return
            }
            selectedRegion = RecordingRegion(displayID: displayID, rect: rect)
            recordingMode = .region
        }
    }

    /// Records what this take captured so the next launch starts here.
    private func rememberCurrentTarget() {
        switch recordingMode {
        case .display:
            guard let selectedDisplayID else { return }
            settings.rememberedTarget = .display(selectedDisplayID)

        case .window:
            guard let window = selectedWindow,
                  let bundleID = window.owningApplication?.bundleIdentifier else { return }
            settings.rememberedTarget = .window(bundleID: bundleID, title: window.title)

        case .region:
            guard let region = selectedRegion else { return }
            settings.rememberedTarget = .region(
                displayID: region.displayID,
                x: region.rect.origin.x,
                y: region.rect.origin.y,
                width: region.rect.width,
                height: region.rect.height
            )
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
    private var cursorTimer: Timer?
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

    private func captureDimensions(for display: SCDisplay, maxHeight: CGFloat?, codec: AppSettings.VideoCodec) -> (width: Int, height: Int) {
        let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2.0
        return Self.outputDimensions(
            width: Int(CGFloat(display.width) * scale),
            height: Int(CGFloat(display.height) * scale),
            maxHeight: maxHeight,
            codec: codec
        )
    }

    private func captureDimensions(for window: SCWindow, maxHeight: CGFloat?, codec: AppSettings.VideoCodec) -> (width: Int, height: Int) {
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
        return Self.outputDimensions(
            width: Int(window.frame.width * scale),
            height: Int(window.frame.height * scale),
            maxHeight: maxHeight,
            codec: codec
        )
    }

    private func captureDimensions(
        forRegion rect: CGRect,
        on display: SCDisplay,
        maxHeight: CGFloat?,
        codec: AppSettings.VideoCodec
    ) -> (width: Int, height: Int) {
        let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2.0
        return Self.outputDimensions(
            width: Int(rect.width * scale),
            height: Int(rect.height * scale),
            maxHeight: maxHeight,
            codec: codec
        )
    }

    /// Applies the configured height cap, preserving aspect ratio, then the
    /// encoder's own limits.
    static func outputDimensions(
        width: Int,
        height: Int,
        maxHeight: CGFloat?,
        codec: AppSettings.VideoCodec
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else {
            return dimensionsFitting(width: width, height: height, maxSize: codec.maxDimensions)
        }

        var scaledWidth = CGFloat(width)
        var scaledHeight = CGFloat(height)
        if let maxHeight, scaledHeight > maxHeight {
            let scale = maxHeight / scaledHeight
            scaledWidth *= scale
            scaledHeight *= scale
        }

        return dimensionsFitting(
            width: Int(scaledWidth.rounded()),
            height: Int(scaledHeight.rounded()),
            maxSize: codec.maxDimensions
        )
    }

    /// Shrinks dimensions to fit an encoder's ceiling, keeping aspect ratio
    /// and even numbers of pixels.
    static func dimensionsFitting(width: Int, height: Int, maxSize: CGSize) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }

        let scale = min(
            1,
            min(
                maxSize.width / CGFloat(width),
                maxSize.height / CGFloat(height)
            )
        )
        let scaledWidth = max(2, Int((CGFloat(width) * scale).rounded(.down)))
        let scaledHeight = max(2, Int((CGFloat(height) * scale).rounded(.down)))

        return (
            width: scaledWidth - (scaledWidth % 2),
            height: scaledHeight - (scaledHeight % 2)
        )
    }

    func startRecording(overrides: RecordingOverrides = .none) async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { finishStarting() }

        // Reset stop signal for new recording
        resetCaptureStopSignal()

        // Snapshot settings once so nothing edited mid-take can change the
        // recording that is already running.
        let options = RecordingOptions(settings: settings, overrides: overrides)
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
            let dimensions = captureDimensions(for: display, maxHeight: options.resolutionMaxHeight, codec: options.videoCodec)
            captureWidth = dimensions.width
            captureHeight = dimensions.height

        case .window:
            guard let window = selectedWindow else {
                errorMessage = "No window selected"
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let dimensions = captureDimensions(for: window, maxHeight: options.resolutionMaxHeight, codec: options.videoCodec)
            captureWidth = dimensions.width
            captureHeight = dimensions.height

        case .region:
            guard let region = selectedRegion,
                  let display = regionDisplay(for: region) else {
                errorMessage = "No region selected"
                return
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            let dimensions = captureDimensions(
                forRegion: region.rect,
                on: display,
                maxHeight: options.resolutionMaxHeight,
                codec: options.videoCodec
            )
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

        // Framing draws the window inset on a larger canvas, so the file is
        // bigger than the capture. The stream still captures at capture size.
        let windowFrame = Self.windowFrame(
            for: recordingMode,
            captureWidth: captureWidth,
            captureHeight: captureHeight,
            options: options
        )
        let outputWidth = windowFrame.map { Int($0.canvasSize.width) } ?? captureWidth
        let outputHeight = windowFrame.map { Int($0.canvasSize.height) } ?? captureHeight

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

            try setupAssetWriter(
                width: outputWidth,
                height: outputHeight,
                options: options,
                windowFrame: windowFrame
            )

            stream = SCStream(filter: filter, configuration: config, delegate: self)

            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamOutputQueue)
            if config.capturesAudio {
                try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
            }

            try await stream?.startCapture()
            let failures = startCaptureSessions()
            lastRecordedURL = nil
            isRecording = true
            rememberCurrentTarget()
            startLowSpaceMonitor()
            if options.highlightClicks {
                startCursorSampling(frameRate: options.frameRate)
            }

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
        isPaused = false
        return true
    }

    /// Stops writing without ending the take. Capture keeps running so
    /// resuming is instant; the gap is removed from the output timeline.
    func pauseRecording() {
        guard isRecording, !isStopping, !isPaused else { return }
        withFrameLock { frameState.isPaused = true }
        isPaused = true
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        withFrameLock { frameState.isPaused = false }
        isPaused = false
    }

    func togglePause() {
        isPaused ? resumeRecording() : pauseRecording()
    }

    /// Ends the recording and throws the file away, for a take the user does
    /// not want kept. Unlike stopRecording, nothing is finalized, nothing is
    /// added to recent recordings, and no preview is offered.
    @discardableResult
    func discardRecording() async -> Bool {
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

        signalCaptureStop()
        stopCaptureSessions()

        do {
            try await stream?.stopCapture()
        } catch {
            logger.warning("Failed to stop capture while discarding: \(error.localizedDescription)")
        }

        assetWriter?.cancelWriting()
        if let outputURL {
            discardTempRecording(outputURL)
        }

        cleanup()
        isRecording = false
        isPaused = false
        errorMessage = nil
        logger.info("Recording discarded at the user's request")
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

    /// Describes the background canvas for a framed window recording, or nil
    /// when the capture is written as-is.
    static func windowFrame(
        for mode: RecordingMode,
        captureWidth: Int,
        captureHeight: Int,
        options: RecordingOptions
    ) -> FrameCompositor.WindowFrame? {
        guard mode == .window, options.frameWindowRecordings else { return nil }

        let contentSize = CGSize(width: captureWidth, height: captureHeight)
        let padding = WindowFrameLayout.padding(contentSize: contentSize)

        return FrameCompositor.WindowFrame(
            canvasSize: WindowFrameLayout.canvasSize(contentSize: contentSize),
            contentOrigin: WindowFrameLayout.contentOrigin(contentSize: contentSize),
            cornerRadius: WindowFrameLayout.cornerRadius(contentSize: contentSize),
            shadowBlur: (padding * WindowFrameLayout.shadowBlurFraction).rounded(),
            background: options.windowBackground
        )
    }

    private func setupAssetWriter(
        width: Int,
        height: Int,
        options: RecordingOptions,
        windowFrame: FrameCompositor.WindowFrame?
    ) throws {
        let outputURL = try makeOutputURL(options: options)
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = makeVideoInput(
            width: width,
            height: height,
            bitrate: options.videoBitrate,
            codec: options.videoCodec
        )

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
            options: options,
            windowFrame: windowFrame
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
        guard let available = RecordingFileStore.availableCapacity(at: directory) else { return nil }
        return RecordingDiskSpace.shortfallMessage(
            availableBytes: available,
            bitrate: options.videoBitrate,
            directory: directory
        )
    }

    private func makeOutputURL(options: RecordingOptions) throws -> URL {
        let outputDir = options.outputDirectory
        do {
            return try RecordingFileStore.makeOutputURL(in: outputDir)
        } catch {
            logger.warning("Configured output directory unavailable (\(outputDir.path()), using fallback: \(error.localizedDescription))")
            let fallback = AppSettings.defaultOutputDirectory()
            persistSettingOutputDirectory(fallback)
            // Keep the in-flight snapshot pointing at the directory actually
            // being written to, so the save panel and space checks agree.
            activeOptions?.outputDirectory = fallback
            return try RecordingFileStore.makeOutputURL(in: fallback)
        }
    }

    private func persistSettingOutputDirectory(_ url: URL) {
        settings.outputDirectory = url
    }

    private func makeVideoInput(
        width: Int,
        height: Int,
        bitrate: Int,
        codec: AppSettings.VideoCodec
    ) -> AVAssetWriterInput {
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
        if let profileLevel = codec.profileLevel {
            compression[AVVideoProfileLevelKey] = profileLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
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
        options: RecordingOptions,
        windowFrame: FrameCompositor.WindowFrame?
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
                textOverlay: options.textOverlay,
                highlightClicks: options.highlightClicks,
                windowFrame: windowFrame
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

    /// Starts the camera ahead of recording so the user can frame themselves
    /// during the countdown instead of doing it on camera. The session is
    /// reused by startRecording, so the camera is only opened once.
    /// Returns false when there is no camera to show.
    func prepareCameraPreview(overrides: RecordingOverrides = .none) async -> Bool {
        guard overrides.recordCamera ?? settings.recordCamera else { return false }
        guard cameraCaptureSession == nil else { return true }
        guard await ensureAVPermission(for: .video) else { return false }
        guard let device = settings.selectedCamera else { return false }

        do {
            try startCameraSession(device: device)
        } catch {
            logger.warning("Could not start camera preview: \(error.localizedDescription)")
            return false
        }

        let running = captureSessionQueue.sync { () -> Bool in
            cameraCaptureSession?.startRunning()
            return cameraCaptureSession?.isRunning ?? false
        }
        if !running {
            discardCameraPreview()
            return false
        }
        return true
    }

    /// Tears down a preview-only camera session, for a cancelled countdown.
    func discardCameraPreview() {
        guard !isRecording else { return }
        disableCameraCaptureAfterStartFailure()
    }

    private func setupCameraCapture(options: RecordingOptions) throws {
        // The countdown may already have opened the camera for framing.
        guard cameraCaptureSession == nil else { return }
        guard let device = options.cameraDevice else {
            throw NSError(domain: "ScreenRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No camera available"])
        }
        try startCameraSession(device: device)
    }

    private func startCameraSession(device: AVCaptureDevice) throws {
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

        if options.askWhereToSave, let requestSaveDestination {
            let request = SaveDestinationRequest(
                suggestedName: tempURL.lastPathComponent,
                directory: options.outputDirectory
            )
            let requestedURL = await requestSaveDestination(request)
            finalURL = RecordingFinalizationLogic.destination(
                tempURL: tempURL,
                requestedURL: requestedURL
            )
            if requestedURL != nil {
                do {
                    replacementWarning = try moveTempRecording(from: tempURL, to: finalURL)
                } catch {
                    guard FileManager.default.fileExists(atPath: tempURL.path()) else {
                        errorMessage = "Failed to save recording: \(error.localizedDescription)"
                        lastRecordedURL = nil
                        return
                    }
                    finalURL = tempURL
                    errorMessage = RecordingFinalizationLogic.retainedRecordingMessage(
                        for: tempURL,
                        saveError: error
                    )
                }
            } else {
                logger.info("Save cancelled; keeping recording at \(tempURL.path(), privacy: .public)")
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
            try RecordingFileStore.discard(tempURL)
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
        stopCursorSampling()
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
            frameState.isPaused = false
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
                errorMessage = errorMessage.map { "\(savedMessage)\n\($0)" } ?? savedMessage
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
        isPaused = false
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

    /// Samples the pointer on the main actor and hands the compositor a
    /// frame-space position. NSEvent.mouseLocation and pressedMouseButtons are
    /// both free of the Accessibility permission a global event tap needs.
    private func startCursorSampling(frameRate: Int) {
        stopCursorSampling()
        let interval = 1.0 / Double(max(1, frameRate))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.samplePressedCursor()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func stopCursorSampling() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        withFrameLock { frameState.pressedCursorPoint = nil }
    }

    private func samplePressedCursor() {
        guard isRecording, !isPaused, NSEvent.pressedMouseButtons != 0 else {
            withFrameLock { frameState.pressedCursorPoint = nil }
            return
        }

        guard let bounds = liveRecordingBounds else {
            withFrameLock { frameState.pressedCursorPoint = nil }
            return
        }

        // Normalized here; the compositor scales to whatever the frame size is.
        let cursor = NSEvent.mouseLocation
        let point = CursorHighlightLayout.framePoint(
            cursor: cursor,
            bounds: bounds,
            frameWidth: 1,
            frameHeight: 1
        )
        withFrameLock { frameState.pressedCursorPoint = point }
    }

    /// Recording bounds that follow a window as it is moved, unlike the
    /// ScreenCaptureKit snapshot taken when recording started.
    private var liveRecordingBounds: CGRect? {
        if recordingMode == .window,
           let windowID = selectedWindow?.windowID,
           let quartz = quartzWindowBounds(windowID: windowID) {
            return cocoaRect(fromQuartz: quartz)
        }
        return recordingBounds
    }

    private func stopIfSpaceCriticallyLow() async {
        guard isRecording, !isStopping else { return }

        let options = activeOptions ?? RecordingOptions(settings: settings)
        let directory = outputURL?.deletingLastPathComponent() ?? options.outputDirectory
        guard let available = RecordingFileStore.availableCapacity(at: directory),
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
        isPaused = false
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
            var pressedCursorPoint: CGPoint?

            var adjustedTime = presentationTime

            withFrameLock {
                guard !frameState.isCaptureStopped else { return }
                guard var writer = frameState.frameWriter else { return }
                guard !writer.hasWriteFailure else { return }

                // Paused: remember where the gap started and drop the frame.
                if frameState.isPaused {
                    if writer.pauseStartTime == nil {
                        writer.pauseStartTime = presentationTime
                        frameState.frameWriter = writer
                    }
                    return
                }

                // First frame after a resume: fold the gap into the running
                // offset so the output timeline stays continuous.
                if let pauseStart = writer.pauseStartTime {
                    writer.pausedDuration = CMTimeAdd(
                        writer.pausedDuration,
                        CMTimeSubtract(presentationTime, pauseStart)
                    )
                    writer.pauseStartTime = nil
                    frameState.frameWriter = writer
                }

                adjustedTime = CMTimeSubtract(presentationTime, writer.pausedDuration)

                cameraBuffer = frameState.latestCameraPixelBuffer

                if writer.startTime == nil {
                    writer.startTime = adjustedTime
                    writer.assetWriter.startSession(atSourceTime: adjustedTime)
                    frameState.frameWriter = writer
                }

                guard writer.videoInput.isReadyForMoreMediaData else { return }

                cameraX = frameState.currentCameraX
                cameraY = frameState.currentCameraY
                cameraSizeFraction = frameState.currentCameraSizeFraction
                pressedCursorPoint = writer.highlightClicks ? frameState.pressedCursorPoint : nil
                writerSnapshot = writer
            }

            guard let snapshot = writerSnapshot else { return }

            var frameToWrite = screenBuffer
            var usedCompositedBuffer = false

            let click = pressedCursorPoint.map { normalized in
                FrameCompositor.ClickHighlight(
                    normalized: normalized,
                    diameterFraction: CursorHighlightLayout.diameterFraction
                )
            }

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
            if cameraOverlay != nil || snapshot.textOverlay != nil || click != nil || snapshot.windowFrame != nil {
                if let composited = compositor.composite(
                    screenBuffer: screenBuffer,
                    camera: cameraOverlay,
                    text: snapshot.textOverlay,
                    click: click,
                    windowFrame: snapshot.windowFrame,
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

                if !writer.adaptor.append(frameToWrite, withPresentationTime: adjustedTime) {
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

    /// Shifts every timestamp in a sample buffer back by an offset, for the
    /// time spent paused. Returns the original buffer when there is no offset.
    private nonisolated func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sampleBuffer }

        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        ) == noErr else { return nil }

        var timings = [CMSampleTimingInfo](repeating: .invalid, count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: count,
            arrayToFill: &timings,
            entriesNeededOut: &count
        ) == noErr else { return nil }

        for index in 0..<count {
            timings[index].presentationTimeStamp = CMTimeSubtract(
                timings[index].presentationTimeStamp,
                offset
            )
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }

        var retimedBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &retimedBuffer
        ) == noErr else { return nil }

        return retimedBuffer
    }

    /// Appends an audio sample (microphone or system audio) to the writer.
    /// Samples arriving before the video session starts are dropped so audio
    /// never leads the first frame.
    private nonisolated func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let writer = withFrameLock { () -> FrameWriter? in
            guard !frameState.isCaptureStopped, !frameState.isPaused else { return nil }
            return frameState.frameWriter
        }

        guard var writer,
              writer.startTime != nil,
              let audio = writer.audioInput,
              audio.isReadyForMoreMediaData
        else { return }

        // Audio carries its own timestamps, so the pause offset has to be
        // applied to the buffer rather than passed alongside it.
        guard let sampleBuffer = retimed(sampleBuffer, by: writer.pausedDuration) else {
            logger.warning("Could not retime audio sample for pause offset; dropping it")
            return
        }

        if !audio.append(sampleBuffer) {
            withFrameLock {
                handleAppendFailure(&writer, context: "Failed to append audio sample")
                frameState.frameWriter = writer
                frameState.isCaptureStopped = true
            }
        }
    }
}
