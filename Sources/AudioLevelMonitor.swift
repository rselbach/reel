@preconcurrency import AVFoundation
import SwiftUI
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel",
    category: "AudioLevelMonitor"
)

enum AudioLevelScale {
    /// Quieter than this is treated as silence. Speech sits well above it,
    /// while room tone from a live microphone sits below.
    static let floorDecibels: Float = -60

    /// Maps AVCaptureAudioChannel's decibel reading onto 0...1 for a meter.
    static func normalized(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        let clamped = min(0, max(floorDecibels, decibels))
        return (clamped - floorDecibels) / -floorDecibels
    }

    /// True once the input is loud enough to be obviously working, used to
    /// decide whether the meter reads as live.
    static func isAudible(level: Float) -> Bool {
        level > 0.08
    }
}

/// Sample buffer delegate that does nothing. AVCaptureAudioDataOutput needs
/// one to run, but the level readings come from the connection's audio
/// channels rather than from the buffers.
private final class DiscardingAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {}

/// Live input level for the selected microphone, so a muted or wrong input is
/// obvious before a take rather than after one.
@MainActor
final class AudioLevelMonitor: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var timer: Timer?
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private let delegate = DiscardingAudioDelegate()
    private let sessionQueue = DispatchQueue(label: "com.rselbach.reel.level-meter")

    /// Polls fast enough to look continuous without being a busy loop.
    private static let refreshInterval: TimeInterval = 1.0 / 20

    func start(device: AVCaptureDevice?) {
        stop()
        errorMessage = nil

        guard let device else {
            errorMessage = AudioLevelText.noInput
            return
        }

        let generation = self.generation
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.startTask = nil
                }
            }
            guard await self.ensureMicrophoneAccess(),
                  !Task.isCancelled,
                  self.generation == generation else {
                if !Task.isCancelled, self.generation == generation {
                    self.errorMessage = AudioLevelText.accessDenied
                }
                return
            }
            self.beginMetering(device: device, generation: generation)
        }
    }

    func stop() {
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        timer?.invalidate()
        timer = nil

        let session = self.session
        self.session = nil
        output = nil
        sessionQueue.async {
            session?.stopRunning()
        }
        level = 0
        isRunning = false
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func beginMetering(device: AVCaptureDevice, generation: Int) {
        guard self.generation == generation else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(delegate, queue: sessionQueue)

        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                errorMessage = AudioLevelText.unavailable
                return
            }
            session.addInput(input)
            session.addOutput(output)
        } catch {
            session.commitConfiguration()
            logger.warning("Could not open \(device.localizedName) for metering: \(error.localizedDescription)")
            errorMessage = AudioLevelText.unavailable
            return
        }
        session.commitConfiguration()

        self.session = session
        self.output = output
        errorMessage = nil

        sessionQueue.async { [weak self] in
            session.startRunning()
            let isRunning = session.isRunning
            Task { @MainActor in
                self?.captureSessionDidStart(
                    session,
                    generation: generation,
                    isRunning: isRunning
                )
            }
        }
    }

    private func captureSessionDidStart(
        _ session: AVCaptureSession,
        generation: Int,
        isRunning: Bool
    ) {
        guard self.generation == generation, self.session === session else { return }
        guard isRunning else {
            self.session = nil
            output = nil
            errorMessage = AudioLevelText.unavailable
            return
        }

        self.isRunning = true
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleLevel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sampleLevel() {
        guard let channel = output?.connection(with: .audio)?.audioChannels.first else {
            level = 0
            return
        }
        level = AudioLevelScale.normalized(decibels: channel.averagePowerLevel)
    }
}

enum AudioLevelText {
    static let label = "Input level:"
    static let noInput = "No microphone available."
    static let accessDenied = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
    static let unavailable = "Could not read the level for this input."
    static let silent = "No sound detected — check the input is not muted."
}

/// Horizontal level meter. Green while sound is arriving, so a silent input
/// reads as a problem rather than as an idle control.
struct AudioLevelMeter: View {
    let level: Float

    private let height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor))

                Capsule()
                    .fill(AudioLevelScale.isAudible(level: level) ? Color.green : Color.orange)
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityLabel(AudioLevelText.label)
        .accessibilityValue("\(Int((min(max(level, 0), 1) * 100).rounded())) percent")
    }
}
