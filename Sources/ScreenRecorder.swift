import AVFoundation
import CoreImage
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum RecordingMode {
    case display
    case window
}

@MainActor
class ScreenRecorder: NSObject, ObservableObject {
    @Published var isRecording = false {
        didSet {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.updateIcon(isRecording: isRecording)
            }
        }
    }
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
    private nonisolated(unsafe) var latestCameraPixelBuffer: CVPixelBuffer?
    private let cameraBufferLock = NSLock()
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var ciContext: CIContext?
    private var startTime: CMTime?
    private var outputURL: URL?

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
                window.frame.width > 100 &&
                window.frame.height > 100 &&
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
            availableWindows = content.windows.filter { window in
                window.isOnScreen &&
                window.frame.width > 100 &&
                window.frame.height > 100 &&
                window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
        } catch {
            errorMessage = "Failed to refresh windows: \(error.localizedDescription)"
        }
    }

    func startRecording() async {
        guard !isRecording else { return }

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
            captureWidth = Int(display.width) * 2
            captureHeight = Int(display.height) * 2

        case .window:
            guard let window = selectedWindow else {
                errorMessage = "No window selected"
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureWidth = Int(window.frame.width) * 2
            captureHeight = Int(window.frame.height) * 2
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
        guard isRecording else { return }

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
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        outputURL = outputDir.appendingPathComponent("Reel-\(timestamp).mp4")

        assetWriter = try AVAssetWriter(outputURL: outputURL!, fileType: .mp4)

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

        if let videoInput, assetWriter?.canAdd(videoInput) == true {
            assetWriter?.add(videoInput)

            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )
            ciContext = CIContext()
        }

        if settings.recordAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true

            if let audioInput, assetWriter?.canAdd(audioInput) == true {
                assetWriter?.add(audioInput)
            }
        }

        assetWriter?.startWriting()
        startTime = nil
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

            let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow())
            if response == .OK, let url = panel.url {
                finalURL = url
                do {
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                } catch {
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                    return
                }
            } else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
        }

        print("Recording saved to: \(finalURL.path)")
        lastRecordedURL = finalURL

        if settings.openFinderAfterRecording && !settings.showPreviewAfterRecording {
            NSWorkspace.shared.selectFile(finalURL.path, inFileViewerRootedAtPath: "")
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
        pixelBufferAdaptor = nil
        ciContext = nil
        cameraBufferLock.lock()
        latestCameraPixelBuffer = nil
        cameraBufferLock.unlock()
        startTime = nil
    }

    nonisolated func compositeFrame(
        screenBuffer: CVPixelBuffer,
        cameraBuffer: CVPixelBuffer?,
        context: CIContext,
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

        let padding: CGFloat = 20 * 2
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

        cameraBufferLock.lock()
        let cameraBuffer = latestCameraPixelBuffer
        cameraBufferLock.unlock()

        nonisolated(unsafe) let capturedScreenBuffer = screenBuffer
        nonisolated(unsafe) let capturedCameraBuffer = cameraBuffer

        Task { @MainActor [weak self] in
            guard let self,
                  let assetWriter = self.assetWriter,
                  let videoInput = self.videoInput,
                  let adaptor = self.pixelBufferAdaptor,
                  let context = self.ciContext
            else { return }

            if self.startTime == nil {
                self.startTime = presentationTime
                assetWriter.startSession(atSourceTime: presentationTime)
            }

            guard videoInput.isReadyForMoreMediaData else { return }

            if self.settings.recordCamera, capturedCameraBuffer != nil {
                if let composited = self.compositeFrame(
                    screenBuffer: capturedScreenBuffer,
                    cameraBuffer: capturedCameraBuffer,
                    context: context,
                    position: self.settings.cameraPosition,
                    sizeFraction: self.settings.cameraSize.fraction,
                    shape: self.settings.cameraShape
                ) {
                    adaptor.append(composited, withPresentationTime: presentationTime)
                } else {
                    adaptor.append(capturedScreenBuffer, withPresentationTime: presentationTime)
                }
            } else {
                adaptor.append(capturedScreenBuffer, withPresentationTime: presentationTime)
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
            cameraBufferLock.lock()
            latestCameraPixelBuffer = pixelBuffer
            cameraBufferLock.unlock()
        } else {
            nonisolated(unsafe) let buffer = sampleBuffer

            Task { @MainActor [weak self] in
                guard let self,
                      let audioInput = self.audioInput,
                      self.startTime != nil
                else { return }

                if audioInput.isReadyForMoreMediaData {
                    audioInput.append(buffer)
                }
            }
        }
    }
}
