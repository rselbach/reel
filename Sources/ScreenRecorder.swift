import AVFoundation
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

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
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

            stream = SCStream(filter: filter, configuration: config, delegate: self)

            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())

            try await stream?.startCapture()
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = "Failed to start: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stopRecording() async {
        guard isRecording else { return }

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
        outputURL = outputDir.appendingPathComponent("Mili-\(timestamp).mp4")

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
        }

        assetWriter?.startWriting()
        startTime = nil
    }

    private func finalizeRecording() async {
        videoInput?.markAsFinished()
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
        if settings.openFinderAfterRecording {
            NSWorkspace.shared.selectFile(finalURL.path, inFileViewerRootedAtPath: "")
        }
    }

    private func cleanup() {
        stream = nil
        assetWriter = nil
        videoInput = nil
        startTime = nil
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

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        nonisolated(unsafe) let buffer = sampleBuffer
        
        MainActor.assumeIsolated {
            guard let assetWriter, let videoInput else { return }

            if startTime == nil {
                startTime = presentationTime
                assetWriter.startSession(atSourceTime: startTime!)
            }

            if videoInput.isReadyForMoreMediaData {
                videoInput.append(buffer)
            }
        }
    }
}
