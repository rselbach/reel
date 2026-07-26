import AVFoundation
import Carbon
import SwiftUI
import XCTest
@testable import Reel

private final class RestoreFailingFileManager: FileManager, @unchecked Sendable {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        if moveCount == 3 {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class BackupCleanupFailingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class PartialDestinationFailingFileManager: FileManager, @unchecked Sendable {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        if moveCount == 2 {
            try Data("partial".utf8).write(to: dstURL)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

final class AppSettingsTests: XCTestCase {
    @MainActor
    private var h264Limits: CGSize { AppSettings.VideoCodec.h264.maxDimensions }

    @MainActor
    func testCameraOverlayPositionNormalizedCoordinates() {
        XCTAssertEqual(AppSettings.CameraOverlayPosition.bottomLeft.normalizedCoordinates.x, 0.0)
        XCTAssertEqual(AppSettings.CameraOverlayPosition.bottomLeft.normalizedCoordinates.y, 0.0)

        XCTAssertEqual(AppSettings.CameraOverlayPosition.topRight.normalizedCoordinates.x, 1.0)
        XCTAssertEqual(AppSettings.CameraOverlayPosition.topRight.normalizedCoordinates.y, 1.0)
    }

    @MainActor
    func testRememberedTargetSurvivesACodingRoundTrip() throws {
        let targets: [RememberedTarget] = [
            .display(7),
            .window(bundleID: "com.greendale.study", title: "Spanish 101"),
            .window(bundleID: "com.greendale.study", title: nil),
            .region(displayID: 2, x: 10, y: 20, width: 640, height: 360)
        ]

        for target in targets {
            let data = try JSONEncoder().encode(target)
            let decoded = try JSONDecoder().decode(RememberedTarget.self, from: data)
            XCTAssertEqual(decoded, target)
        }
    }

    @MainActor
    func testRememberedWindowRequiresOneExactAppAndTitleMatch() {
        let bundleIDs: [String?] = [
            "com.greendale.study",
            "com.greendale.study",
            "com.greendale.dean",
            "com.greendale.study"
        ]
        let titles: [String?] = ["Spanish 101", "Biology 101", "Dean's Office", nil]

        XCTAssertEqual(
            RememberedTargetMatching.bestMatchIndex(
                bundleIDs: bundleIDs,
                titles: titles,
                wantedBundleID: "com.greendale.study",
                wantedTitle: "Biology 101"
            ),
            1
        )

        XCTAssertNil(
            RememberedTargetMatching.bestMatchIndex(
                bundleIDs: bundleIDs,
                titles: titles,
                wantedBundleID: "com.greendale.study",
                wantedTitle: "Anthropology 101"
            )
        )

        XCTAssertEqual(
            RememberedTargetMatching.bestMatchIndex(
                bundleIDs: bundleIDs,
                titles: titles,
                wantedBundleID: "com.greendale.study",
                wantedTitle: nil
            ),
            3
        )

        XCTAssertNil(
            RememberedTargetMatching.bestMatchIndex(
                bundleIDs: bundleIDs,
                titles: titles,
                wantedBundleID: "com.greendale.cafeteria",
                wantedTitle: nil
            )
        )

        XCTAssertNil(
            RememberedTargetMatching.bestMatchIndex(
                bundleIDs: [
                    "com.greendale.study",
                    "com.greendale.study"
                ],
                titles: ["Spanish 101", "Spanish 101"],
                wantedBundleID: "com.greendale.study",
                wantedTitle: "Spanish 101"
            ),
            "duplicate titles are ambiguous and must not select either window"
        )
    }

    @MainActor
    func testRecordingOptionsSnapshotMatchesSettingsAtStart() {
        let settings = AppSettings.shared
        let options = RecordingOptions(settings: settings)

        XCTAssertEqual(options.frameRate, settings.frameRate)
        XCTAssertEqual(options.showCursor, settings.showCursor)
        XCTAssertEqual(options.videoBitrate, settings.videoQuality.bitrate)
        XCTAssertEqual(options.outputDirectory, settings.outputDirectory)
        XCTAssertEqual(options.askWhereToSave, settings.askWhereToSave)
        XCTAssertEqual(options.recordAudio, settings.recordAudio)
        XCTAssertEqual(options.recordCamera, settings.recordCamera)
        XCTAssertEqual(options.cameraShape, settings.cameraShape)
        XCTAssertEqual(options.cameraSizeFraction, settings.cameraSizeFraction)
        XCTAssertEqual(options.textOverlay?.text, settings.activeTextOverlayText)
    }

    @MainActor
    func testRecordingOptionsDoNotFollowLaterSettingsEdits() {
        let settings = AppSettings.shared
        let originalQuality = settings.videoQuality
        let originalCursor = settings.showCursor
        defer {
            settings.videoQuality = originalQuality
            settings.showCursor = originalCursor
        }

        settings.videoQuality = .low
        settings.showCursor = true
        let options = RecordingOptions(settings: settings)

        settings.videoQuality = .maximum
        settings.showCursor = false

        XCTAssertEqual(options.videoBitrate, AppSettings.VideoQuality.low.bitrate)
        XCTAssertTrue(options.showCursor)
    }

    @MainActor
    func testRecordingOptionsOnlyMirrorFrontFacingCameras() {
        var options = RecordingOptions(settings: AppSettings.shared)
        options.recordCamera = false
        options.cameraDevice = nil
        XCTAssertFalse(options.mirrorCamera)

        // Without a device the position is unknown, which must not be treated
        // as front-facing: external and continuity cameras report
        // .unspecified and are never mirrored.
        options.recordCamera = true
        XCTAssertFalse(options.mirrorCamera)
    }

    @MainActor
    func testDiskSpaceRequirementScalesWithBitrate() {
        let medium = AppSettings.VideoQuality.medium.bitrate
        let maximum = AppSettings.VideoQuality.maximum.bitrate

        XCTAssertEqual(RecordingDiskSpace.bytesPerSecond(bitrate: medium), 1_375_000)
        XCTAssertGreaterThan(
            RecordingDiskSpace.requiredBytes(bitrate: maximum),
            RecordingDiskSpace.requiredBytes(bitrate: medium)
        )
        XCTAssertEqual(
            RecordingDiskSpace.requiredBytes(bitrate: medium),
            RecordingDiskSpace.bytesPerSecond(bitrate: medium) * 120
        )
    }

    @MainActor
    func testDiskSpaceShortfallOnlyReportedBelowTheFloor() {
        let bitrate = AppSettings.VideoQuality.medium.bitrate
        let required = RecordingDiskSpace.requiredBytes(bitrate: bitrate)
        let directory = URL(fileURLWithPath: "/Users/troy/Movies", isDirectory: true)

        XCTAssertNil(
            RecordingDiskSpace.shortfallMessage(
                availableBytes: required,
                bitrate: bitrate,
                directory: directory
            )
        )
        XCTAssertNil(
            RecordingDiskSpace.shortfallMessage(
                availableBytes: required * 10,
                bitrate: bitrate,
                directory: directory
            )
        )

        let message = RecordingDiskSpace.shortfallMessage(
            availableBytes: required - 1,
            bitrate: bitrate,
            directory: directory
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Movies") ?? false)
        XCTAssertTrue(message?.contains("video quality") ?? false)
    }

    @MainActor
    func testDiskSpaceRecordableSecondsHandlesEmptyVolume() {
        let bitrate = AppSettings.VideoQuality.high.bitrate
        XCTAssertEqual(
            RecordingDiskSpace.recordableSeconds(availableBytes: 0, bitrate: bitrate),
            0
        )
        XCTAssertEqual(
            RecordingDiskSpace.recordableSeconds(availableBytes: -100, bitrate: bitrate),
            0
        )
        XCTAssertEqual(
            RecordingDiskSpace.recordableSeconds(
                availableBytes: RecordingDiskSpace.bytesPerSecond(bitrate: bitrate) * 30,
                bitrate: bitrate
            ),
            30,
            accuracy: 0.001
        )
    }

    @MainActor
    func testLowSpaceStopTriggersBeforeTheWriterRunsOut() {
        let bitrate = AppSettings.VideoQuality.medium.bitrate
        let perSecond = RecordingDiskSpace.bytesPerSecond(bitrate: bitrate)

        XCTAssertFalse(
            RecordingDiskSpace.isCriticallyLow(availableBytes: perSecond * 60, bitrate: bitrate)
        )
        XCTAssertTrue(
            RecordingDiskSpace.isCriticallyLow(availableBytes: perSecond * 10, bitrate: bitrate)
        )
        XCTAssertTrue(
            RecordingDiskSpace.isCriticallyLow(availableBytes: 0, bitrate: bitrate)
        )

        // The stop floor has to sit below the start floor, otherwise every
        // recording that is allowed to start stops itself immediately.
        XCTAssertLessThan(
            RecordingDiskSpace.stopSeconds,
            RecordingDiskSpace.minimumMinutes * 60
        )
    }

    @MainActor
    func testLowSpaceReasonNamesRemainingSpace() {
        let reason = RecordingDiskSpace.lowSpaceReason(availableBytes: 5_000_000)
        XCTAssertTrue(reason.contains("disk is almost full"))
        XCTAssertTrue(reason.contains("MB"))
    }

    @MainActor
    func testRatioLockedDragFollowsTheDominantAxis() {
        let anchor = CGPoint(x: 100, y: 100)

        // Wide drag: width wins, height derived from it.
        let wide = RegionAspectConstraint.rect(anchor: anchor, current: CGPoint(x: 1060, y: 200))
        XCTAssertEqual(wide.width, 960, accuracy: 0.001)
        XCTAssertEqual(wide.height, 540, accuracy: 0.001)

        // Tall drag: height wins.
        let tall = RegionAspectConstraint.rect(anchor: anchor, current: CGPoint(x: 200, y: 640))
        XCTAssertEqual(tall.height, 540, accuracy: 0.001)
        XCTAssertEqual(tall.width, 960, accuracy: 0.001)

        XCTAssertEqual(wide.width / wide.height, RegionAspectConstraint.ratio, accuracy: 0.001)
    }

    @MainActor
    func testRatioLockedDragWorksInEveryDirection() {
        let anchor = CGPoint(x: 1000, y: 800)

        // Up and to the left of the anchor.
        let rect = RegionAspectConstraint.rect(anchor: anchor, current: CGPoint(x: 40, y: 200))
        XCTAssertEqual(rect.maxX, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 800, accuracy: 0.001)
        XCTAssertEqual(rect.width / rect.height, RegionAspectConstraint.ratio, accuracy: 0.001)
    }

    @MainActor
    func testRatioLockedDragPreservesItsShapeAtScreenEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rect = RegionAspectConstraint.rect(
            anchor: CGPoint(x: 700, y: 500),
            current: CGPoint(x: 1200, y: 900),
            in: bounds
        )

        XCTAssertTrue(bounds.contains(rect))
        XCTAssertEqual(rect.width / rect.height, RegionAspectConstraint.ratio, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, bounds.maxX, accuracy: 0.001)
    }

    @MainActor
    func testRatioLockedResizeKeepsTheRatio() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 100, y: 100, width: 960, height: 540)

        let resized = RegionAdjustment.adjusted(
            rect: rect,
            handle: .topRight,
            delta: CGPoint(x: 320, y: 0),
            bounds: screen,
            minimumSize: RegionMath.minimumSelectionSize,
            lockedRatio: RegionAspectConstraint.ratio
        )
        XCTAssertEqual(resized.width / resized.height, RegionAspectConstraint.ratio, accuracy: 0.01)

        // Without the lock the ratio is free to change.
        let unlocked = RegionAdjustment.adjusted(
            rect: rect,
            handle: .topRight,
            delta: CGPoint(x: 320, y: 0),
            bounds: screen,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(unlocked.height, 540)
        XCTAssertEqual(unlocked.width, 1280)
    }

    @MainActor
    func testRatioLockedResizePreservesItsShapeAtScreenEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rect = CGRect(x: 500, y: 300, width: 160, height: 90)
        let resized = RegionAdjustment.adjusted(
            rect: rect,
            handle: .topRight,
            delta: CGPoint(x: 500, y: 500),
            bounds: bounds,
            minimumSize: RegionMath.minimumSelectionSize,
            lockedRatio: RegionAspectConstraint.ratio
        )

        XCTAssertTrue(bounds.contains(resized))
        XCTAssertEqual(resized.width / resized.height, RegionAspectConstraint.ratio, accuracy: 0.001)
        XCTAssertEqual(resized.maxX, bounds.maxX, accuracy: 0.001)
    }

    @MainActor
    func testSelectionHandleHitTesting() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: 100, y: 100), in: rect), .bottomLeft)
        XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: 500, y: 100), in: rect), .bottomRight)
        XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: 100, y: 400), in: rect), .topLeft)
        XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: 500, y: 400), in: rect), .topRight)
        XCTAssertEqual(RegionAdjustment.handle(at: CGPoint(x: 300, y: 250), in: rect), .move)
        XCTAssertNil(RegionAdjustment.handle(at: CGPoint(x: 900, y: 250), in: rect))
    }

    @MainActor
    func testSelectionMoveStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        let moved = RegionAdjustment.adjusted(
            rect: rect,
            handle: .move,
            delta: CGPoint(x: 50, y: -30),
            bounds: screen,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(moved, CGRect(x: 150, y: 70, width: 400, height: 300))

        // Dragged past the edge: clamped, not pushed off screen.
        let clamped = RegionAdjustment.adjusted(
            rect: rect,
            handle: .move,
            delta: CGPoint(x: -500, y: -500),
            bounds: screen,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(clamped.minX, 0)
        XCTAssertEqual(clamped.minY, 0)
        XCTAssertEqual(clamped.size, rect.size, "moving must not resize")
    }

    @MainActor
    func testSelectionResizeAnchorsTheOppositeCornerAndEnforcesAMinimum() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

        let grown = RegionAdjustment.adjusted(
            rect: rect,
            handle: .topRight,
            delta: CGPoint(x: 100, y: 50),
            bounds: screen,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertEqual(grown, CGRect(x: 100, y: 100, width: 500, height: 350))

        // Dragged back past the anchor: standardized and held at the minimum
        // rather than becoming negative.
        let collapsed = RegionAdjustment.adjusted(
            rect: rect,
            handle: .topRight,
            delta: CGPoint(x: -800, y: -800),
            bounds: screen,
            minimumSize: RegionMath.minimumSelectionSize
        )
        XCTAssertGreaterThanOrEqual(collapsed.width, RegionMath.minimumSelectionSize)
        XCTAssertGreaterThanOrEqual(collapsed.height, RegionMath.minimumSelectionSize)
        XCTAssertTrue(screen.contains(collapsed))
    }

    @MainActor
    func testSelectionReadoutReportsPixelDimensions() {
        XCTAssertEqual(
            RegionSelectionLabel.text(
                for: CGRect(x: 10, y: 20, width: 640, height: 360),
                backingScaleFactor: 2,
                maxHeight: nil,
                codec: .h264
            ),
            "1280 × 720 px"
        )
        XCTAssertEqual(
            RegionSelectionLabel.text(
                for: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                backingScaleFactor: 2,
                maxHeight: 1080,
                codec: .h264
            ),
            "1920 × 1080 px"
        )
    }

    @MainActor
    func testSelectionReadoutStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let labelSize = CGSize(width: 90, height: 24)

        // Normal case: centered just above the selection.
        let above = RegionSelectionLabel.origin(
            for: CGRect(x: 800, y: 400, width: 300, height: 200),
            labelSize: labelSize,
            in: screen
        )
        XCTAssertEqual(above.y, 600 + RegionSelectionLabel.margin)
        XCTAssertEqual(above.x, 950 - 45)

        // Selection against the top edge: flipped inside rather than clipped.
        let flipped = RegionSelectionLabel.origin(
            for: CGRect(x: 800, y: 900, width: 300, height: 180),
            labelSize: labelSize,
            in: screen
        )
        XCTAssertLessThanOrEqual(flipped.y + labelSize.height, screen.maxY)

        // Selection against the left edge: kept inside horizontally.
        let clampedLeft = RegionSelectionLabel.origin(
            for: CGRect(x: 0, y: 400, width: 40, height: 40),
            labelSize: labelSize,
            in: screen
        )
        XCTAssertGreaterThanOrEqual(clampedLeft.x, screen.minX)
    }

    @MainActor
    func testGIFSamplingHitsTargetFrameRateForShortClips() {
        let sampling = GIFExport.frames(start: 2, end: 7)
        XCTAssertEqual(sampling.times.count, 60, "5 seconds at 12 fps")
        XCTAssertEqual(sampling.times.first ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(sampling.delay, 1.0 / GIFExport.frameRate, accuracy: 0.0001)
        XCTAssertLessThan(sampling.times.last ?? .infinity, 7)
    }

    @MainActor
    func testGIFSamplingThinsLongClipsRatherThanTruncatingThem() {
        // Ten minutes: far beyond the frame cap.
        let sampling = GIFExport.frames(start: 0, end: 600)
        XCTAssertEqual(sampling.times.count, GIFExport.maxFrames)
        // The whole range is still represented, just sampled more sparsely,
        // and the delay keeps playback at real speed.
        XCTAssertGreaterThan(sampling.times.last ?? 0, 590)
        XCTAssertEqual(sampling.delay, 600 / Double(GIFExport.maxFrames), accuracy: 0.0001)
    }

    @MainActor
    func testGIFSamplingHandlesAnEmptyRange() {
        let sampling = GIFExport.frames(start: 4, end: 4)
        XCTAssertEqual(sampling.times, [4])
        XCTAssertGreaterThan(sampling.delay, 0)
    }

    func testExportsUseHiddenSiblingFilesBeforeAtomicReplacement() {
        let videoOutput = URL(fileURLWithPath: "/tmp/Greendale/demo.mp4")
        let gifOutput = URL(fileURLWithPath: "/tmp/Greendale/demo.gif")

        let videoTemp = ExportFileNaming.temporaryURL(
            for: videoOutput,
            identifier: "Troy"
        )
        let gifTemp = ExportFileNaming.temporaryURL(
            for: gifOutput,
            identifier: "Abed"
        )

        XCTAssertEqual(videoTemp.path(), "/tmp/Greendale/.demo-Troy.mp4")
        XCTAssertEqual(gifTemp.path(), "/tmp/Greendale/.demo-Abed.gif")
        XCTAssertNotEqual(videoTemp, videoOutput)
        XCTAssertNotEqual(gifTemp, gifOutput)
    }

    @MainActor
    func testPerTakeOverridesReplaceOnlyWhatTheyName() {
        let settings = AppSettings.shared
        let originalAudio = settings.recordAudio
        let originalCamera = settings.recordCamera
        defer {
            settings.recordAudio = originalAudio
            settings.recordCamera = originalCamera
        }

        settings.recordAudio = false
        settings.recordCamera = false

        let audioOnly = RecordingOptions(
            settings: settings,
            overrides: RecordingOverrides(recordAudio: true, recordCamera: nil)
        )
        XCTAssertTrue(audioOnly.recordAudio)
        XCTAssertFalse(audioOnly.recordCamera, "an unset override must fall through to the setting")

        settings.recordCamera = true
        let cameraOff = RecordingOptions(
            settings: settings,
            overrides: RecordingOverrides(recordAudio: nil, recordCamera: false)
        )
        XCTAssertFalse(cameraOff.recordCamera)
        XCTAssertNil(cameraOff.cameraDevice, "no camera is opened for a take that turned it off")
    }

    @MainActor
    func testEmptyOverridesLeaveTheSavedDefaultsAlone() {
        let settings = AppSettings.shared
        let plain = RecordingOptions(settings: settings)
        let explicit = RecordingOptions(settings: settings, overrides: .none)

        XCTAssertTrue(RecordingOverrides.none.isEmpty)
        XCTAssertEqual(plain.recordAudio, settings.recordAudio)
        XCTAssertEqual(explicit.recordCamera, settings.recordCamera)
    }

    @MainActor
    func testUnavailableExplicitDevicesDoNotSilentlyUseDefaults() {
        let settings = AppSettings.shared
        let originalAudioID = settings.audioDeviceID
        let originalCameraID = settings.cameraDeviceID
        defer {
            settings.audioDeviceID = originalAudioID
            settings.cameraDeviceID = originalCameraID
        }

        settings.audioDeviceID = "com.greendale.missing-microphone"
        settings.cameraDeviceID = "com.greendale.missing-camera"

        XCTAssertNil(settings.selectedAudioDevice)
        XCTAssertNil(settings.selectedCamera)
    }

    @MainActor
    func testFailedRecordingStartReturnsFalseAndReleasesItsOptions() async {
        let recorder = ScreenRecorder()
        recorder.recordingMode = .display
        recorder.selectedDisplayID = nil

        let started = await recorder.startRecording()

        XCTAssertFalse(started)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isStarting)
        XCTAssertNil(recorder.activeRecordingOptions)
        XCTAssertEqual(recorder.errorMessage, "No display selected")
    }

    func testRecordingSourceFailuresDescribeTheMissingTrack() {
        XCTAssertEqual(
            RecordingSourceError.cannotConnectInput("microphone").errorDescription,
            "Could not connect the selected microphone."
        )
        XCTAssertEqual(
            RecordingSourceError.cannotConnectOutput("camera").errorDescription,
            "Could not connect the camera output."
        )
        XCTAssertEqual(
            RecordingSourceError.cannotAddAudioTrack.errorDescription,
            "Could not add an audio track to the recording."
        )
        XCTAssertEqual(
            RecordingSourceError.failedToStart(["microphone", "camera"]).errorDescription,
            "Microphone and camera failed to start."
        )
    }

    func testAudioWaitsForVideoToCommitTheResumeOffset() {
        XCTAssertTrue(RecordingTimeline.canAppendAudio(
            captureStopped: false,
            paused: false,
            sessionStarted: true,
            awaitingResumeFrame: false
        ))
        XCTAssertFalse(RecordingTimeline.canAppendAudio(
            captureStopped: false,
            paused: true,
            sessionStarted: true,
            awaitingResumeFrame: false
        ))
        XCTAssertFalse(RecordingTimeline.canAppendAudio(
            captureStopped: false,
            paused: false,
            sessionStarted: true,
            awaitingResumeFrame: true
        ))
        XCTAssertFalse(RecordingTimeline.canAppendAudio(
            captureStopped: true,
            paused: false,
            sessionStarted: true,
            awaitingResumeFrame: false
        ))
    }

    @MainActor
    func testAudioLevelScaleMapsDecibelsOntoTheMeter() {
        XCTAssertEqual(AudioLevelScale.normalized(decibels: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelScale.normalized(decibels: -30), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelScale.normalized(decibels: AudioLevelScale.floorDecibels), 0, accuracy: 0.0001)

        // Below the floor and out of range readings clamp rather than
        // producing a negative or oversized bar.
        XCTAssertEqual(AudioLevelScale.normalized(decibels: -120), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelScale.normalized(decibels: 12), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelScale.normalized(decibels: -.infinity), 0)
        XCTAssertEqual(AudioLevelScale.normalized(decibels: .nan), 0)
    }

    @MainActor
    func testAudioLevelAudibilityDistinguishesSilenceFromSpeech() {
        // Room tone sits near the floor; speech is well above it.
        XCTAssertFalse(AudioLevelScale.isAudible(level: AudioLevelScale.normalized(decibels: -58)))
        XCTAssertTrue(AudioLevelScale.isAudible(level: AudioLevelScale.normalized(decibels: -20)))
    }

    @MainActor
    func testBackgroundPresetsCoverSolidAndGradientFills() {
        var solids = 0
        var gradients = 0
        var keys = Set<String>()

        for background in AppSettings.WindowBackground.allCases {
            switch background.fill {
            case .solid: solids += 1
            case .linearGradient: gradients += 1
            }
            keys.insert(background.fill.cacheKey)
        }

        XCTAssertGreaterThan(solids, 0)
        XCTAssertGreaterThan(gradients, 0)
        // Distinct cache keys, or one background would render as another.
        XCTAssertEqual(keys.count, AppSettings.WindowBackground.allCases.count)
    }

    @MainActor
    func testFramedWindowCanvasIsPaddedCenteredAndEvenSized() {
        let content = CGSize(width: 1440, height: 900)
        let padding = WindowFrameLayout.padding(contentSize: content)
        let canvas = WindowFrameLayout.canvasSize(contentSize: content)
        let origin = WindowFrameLayout.contentOrigin(contentSize: content)

        XCTAssertEqual(canvas.width.truncatingRemainder(dividingBy: 2), 0, "encoders reject odd dimensions")
        XCTAssertEqual(canvas.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertGreaterThan(canvas.width, content.width)
        XCTAssertGreaterThan(canvas.height, content.height)
        XCTAssertEqual(canvas.width, (content.width + padding * 2).rounded())

        // Centered: the same margin on both sides.
        XCTAssertEqual(origin.x, (canvas.width - content.width) / 2, accuracy: 1)
        XCTAssertEqual(origin.y, (canvas.height - content.height) / 2, accuracy: 1)
    }

    @MainActor
    func testFramedWindowCanvasHandlesOddContentSizes() {
        let canvas = WindowFrameLayout.canvasSize(contentSize: CGSize(width: 1001, height: 667))
        XCTAssertEqual(canvas.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(canvas.height.truncatingRemainder(dividingBy: 2), 0)
    }

    @MainActor
    func testFramedWindowContentFitsTheFinalCanvasWithinCodecLimits() {
        let dimensions = ScreenRecorder.framedContentDimensionsFitting(
            width: 4096,
            height: 2304,
            maxSize: h264Limits
        )
        let canvas = WindowFrameLayout.canvasSize(
            contentSize: CGSize(width: dimensions.width, height: dimensions.height)
        )

        XCTAssertLessThan(dimensions.width, 4096)
        XCTAssertLessThanOrEqual(canvas.width, h264Limits.width)
        XCTAssertLessThanOrEqual(canvas.height, h264Limits.height)
        XCTAssertEqual(dimensions.width % 2, 0)
        XCTAssertEqual(dimensions.height % 2, 0)
        XCTAssertEqual(
            Double(dimensions.width) / Double(dimensions.height),
            16.0 / 9.0,
            accuracy: 0.01
        )

        let p1080Dimensions = ScreenRecorder.framedContentDimensionsFitting(
            width: 1920,
            height: 1080,
            maxSize: CGSize(width: h264Limits.width, height: 1080)
        )
        let p1080Canvas = WindowFrameLayout.canvasSize(
            contentSize: CGSize(
                width: p1080Dimensions.width,
                height: p1080Dimensions.height
            )
        )
        XCTAssertLessThanOrEqual(p1080Canvas.height, 1080)
    }

    func testRawFrameFallbackIsRejectedForFramedOutput() {
        XCTAssertTrue(FrameFallbackLogic.canAppendRawFrame(hasWindowFrame: false))
        XCTAssertFalse(FrameFallbackLogic.canAppendRawFrame(hasWindowFrame: true))
    }

    @MainActor
    func testFramingAppliesOnlyToWindowRecordings() {
        var options = RecordingOptions(settings: AppSettings.shared)
        options.frameWindowRecordings = true

        XCTAssertNotNil(
            ScreenRecorder.windowFrame(for: .window, captureWidth: 1280, captureHeight: 720, options: options)
        )
        XCTAssertNil(
            ScreenRecorder.windowFrame(for: .display, captureWidth: 1280, captureHeight: 720, options: options)
        )
        XCTAssertNil(
            ScreenRecorder.windowFrame(for: .region, captureWidth: 1280, captureHeight: 720, options: options)
        )

        options.frameWindowRecordings = false
        XCTAssertNil(
            ScreenRecorder.windowFrame(for: .window, captureWidth: 1280, captureHeight: 720, options: options)
        )
    }

    @MainActor
    func testCursorMapsFromGlobalScreenSpaceIntoTheFrame() {
        // A capture area on a second display, offset from the global origin.
        let bounds = CGRect(x: 1440, y: 200, width: 1280, height: 720)

        let centre = CursorHighlightLayout.framePoint(
            cursor: CGPoint(x: 1440 + 640, y: 200 + 360),
            bounds: bounds,
            frameWidth: 2560,
            frameHeight: 1440
        )
        XCTAssertEqual(centre?.x ?? 0, 1280, accuracy: 0.001)
        XCTAssertEqual(centre?.y ?? 0, 720, accuracy: 0.001)

        let origin = CursorHighlightLayout.framePoint(
            cursor: CGPoint(x: 1440, y: 200),
            bounds: bounds,
            frameWidth: 2560,
            frameHeight: 1440
        )
        XCTAssertEqual(origin?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(origin?.y ?? -1, 0, accuracy: 0.001)
    }

    @MainActor
    func testCursorOutsideTheCaptureAreaIsNotHighlighted() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        XCTAssertNil(
            CursorHighlightLayout.framePoint(
                cursor: CGPoint(x: 2000, y: 360),
                bounds: bounds,
                frameWidth: 1280,
                frameHeight: 720
            )
        )
        XCTAssertNil(
            CursorHighlightLayout.framePoint(
                cursor: CGPoint(x: 100, y: 100),
                bounds: .zero,
                frameWidth: 1280,
                frameHeight: 720
            )
        )
    }

    @MainActor
    func testClickHighlightScalesWithFrameHeightButHasAFloor() {
        XCTAssertEqual(CursorHighlightLayout.diameter(frameHeight: 1080), 59)
        XCTAssertGreaterThan(
            CursorHighlightLayout.diameter(frameHeight: 2160),
            CursorHighlightLayout.diameter(frameHeight: 1080)
        )
        // Tiny area recordings still get a visible mark.
        XCTAssertEqual(
            CursorHighlightLayout.diameter(frameHeight: 100),
            CursorHighlightLayout.minimumDiameter
        )
    }

    @MainActor
    func testResolutionCapPreservesAspectRatioAndEvenDimensions() {
        // A Retina 16:10 display captured at 2x, capped to 1080p.
        let capped = ScreenRecorder.outputDimensions(width: 3456, height: 2160, maxHeight: 1080, codec: .h264)
        XCTAssertEqual(capped.height, 1080)
        XCTAssertEqual(capped.width, 1728)
        XCTAssertEqual(capped.width % 2, 0)
        XCTAssertEqual(capped.height % 2, 0)

        // Already below the cap: left alone.
        let small = ScreenRecorder.outputDimensions(width: 1280, height: 720, maxHeight: 1080, codec: .h264)
        XCTAssertEqual(small.width, 1280)
        XCTAssertEqual(small.height, 720)

        // Native: only the encoder's own limits apply.
        let native = ScreenRecorder.outputDimensions(width: 5120, height: 2880, maxHeight: nil, codec: .h264)
        XCTAssertEqual(
            native.width,
            ScreenRecorder.dimensionsFitting(
                width: 5120,
                height: 2880,
                maxSize: AppSettings.VideoCodec.h264.maxDimensions
            ).width
        )
    }

    @MainActor
    func testResolutionCapStillObeysEncoderLimits() {
        // 1440p on an ultra-wide is still within the H.264 width ceiling only
        // because the cap runs first; verify both limits are applied.
        let wide = ScreenRecorder.outputDimensions(width: 10240, height: 2880, maxHeight: 1440, codec: .h264)
        XCTAssertLessThanOrEqual(wide.width, 4096)
        XCTAssertLessThanOrEqual(wide.height, 1440)
        XCTAssertEqual(wide.width % 2, 0)
        XCTAssertEqual(wide.height % 2, 0)
    }

    @MainActor
    func testHevcAllowsLargerFramesThanH264() {
        let h264 = AppSettings.VideoCodec.h264.maxDimensions
        let hevc = AppSettings.VideoCodec.hevc.maxDimensions
        XCTAssertGreaterThan(hevc.width, h264.width)
        XCTAssertGreaterThan(hevc.height, h264.height)

        // A 5K display fits natively under HEVC but is scaled down for H.264.
        let underHevc = ScreenRecorder.outputDimensions(width: 5120, height: 2880, maxHeight: nil, codec: .hevc)
        let underH264 = ScreenRecorder.outputDimensions(width: 5120, height: 2880, maxHeight: nil, codec: .h264)
        XCTAssertEqual(underHevc.width, 5120)
        XCTAssertLessThan(underH264.width, 5120)
    }

    @MainActor
    func testOnlyH264CarriesAnExplicitProfileLevel() {
        // AVVideoProfileLevelH264HighAutoLevel is not a valid value for HEVC,
        // so HEVC must be left to choose its own.
        XCTAssertEqual(AppSettings.VideoCodec.h264.profileLevel, AVVideoProfileLevelH264HighAutoLevel)
        XCTAssertNil(AppSettings.VideoCodec.hevc.profileLevel)
        XCTAssertEqual(AppSettings.VideoCodec.hevc.avCodec, .hevc)
    }

    @MainActor
    func testVideoResolutionHeights() {
        XCTAssertNil(AppSettings.VideoResolution.native.maxHeight)
        XCTAssertEqual(AppSettings.VideoResolution.p720.maxHeight, 720)
        XCTAssertEqual(AppSettings.VideoResolution.p1080.maxHeight, 1080)
        XCTAssertEqual(AppSettings.VideoResolution.p1440.maxHeight, 1440)
    }

    @MainActor
    func testVideoQualityBitrates() {
        XCTAssertEqual(AppSettings.VideoQuality.low.bitrate, 5_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.medium.bitrate, 10_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.high.bitrate, 20_000_000)
        XCTAssertEqual(AppSettings.VideoQuality.maximum.bitrate, 50_000_000)
    }

    @MainActor
    func testStoredSettingRawValuesAreStableKeys() {
        XCTAssertEqual(AppSettings.VideoQuality.medium.rawValue, "medium")
        XCTAssertEqual(AppSettings.AudioSource.systemAudio.rawValue, "systemAudio")
        XCTAssertEqual(AppSettings.CameraOverlayPosition.bottomRight.rawValue, "bottomRight")
        XCTAssertEqual(AppSettings.CameraOverlaySize.large.rawValue, "large")
        XCTAssertEqual(AppSettings.CameraOverlayShape.circle.rawValue, "circle")
        XCTAssertEqual(AppSettings.TextOverlayPosition.center.rawValue, "center")
    }

    @MainActor
    func testStoredSettingDecodingAcceptsStableKeysAndLegacyLabels() {
        XCTAssertEqual(AppSettings.VideoQuality.fromStored("medium"), .medium)
        XCTAssertEqual(AppSettings.VideoQuality.fromStored("Medium (10 Mbps)"), .medium)
        XCTAssertNil(AppSettings.VideoQuality.fromStored("bogus"))
        XCTAssertNil(AppSettings.VideoQuality.fromStored(nil))

        XCTAssertEqual(AppSettings.CameraOverlayPosition.fromStored("Bottom Right"), .bottomRight)
        XCTAssertEqual(AppSettings.CameraOverlaySize.fromStored("Large"), .large)
        XCTAssertEqual(AppSettings.CameraOverlayShape.fromStored("Circle"), .circle)
        XCTAssertEqual(AppSettings.TextOverlayPosition.fromStored("Center"), .center)
        XCTAssertEqual(AppSettings.AudioSource.fromStored("System Audio"), .systemAudio)
        XCTAssertEqual(AppSettings.AudioSource.fromStored("microphone"), .microphone)
    }

    @MainActor
    func testHotkeyActionIdentifiersAreDistinctAndNonZero() {
        let ids = HotkeyAction.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "Carbon needs a distinct id per hot key")
        XCTAssertFalse(ids.contains(0), "0 is reserved as an unset EventHotKeyID")
        XCTAssertEqual(HotkeyAction.toggleRecording.rawValue, 1)
        XCTAssertEqual(HotkeyAction.discardRecording.rawValue, 2)
        XCTAssertEqual(HotkeyAction.pauseRecording.rawValue, 3)
    }

    @MainActor
    func testDefaultShortcutsDoNotCollide() {
        let defaults = HotkeyAction.allCases.map { action -> AppSettings.HotkeyCombo in
            switch action {
            case .toggleRecording: return .default
            case .discardRecording: return .discardDefault
            case .pauseRecording: return .pauseDefault
            }
        }
        XCTAssertEqual(Set(defaults.map(\.displayString)).count, defaults.count)
        XCTAssertTrue(defaults.allSatisfy(\.isUsableGlobalShortcut))
    }

    @MainActor
    func testAssigningATakenShortcutIsRefused() {
        let settings = AppSettings.shared
        let originalToggle = settings.recordingHotkey
        let originalDiscard = settings.discardHotkey
        defer {
            settings.recordingHotkey = originalToggle
            settings.discardHotkey = originalDiscard
            settings.hotkeyConflictError = nil
        }

        settings.setHotkey(.default, for: .toggleRecording)
        settings.setHotkey(.discardDefault, for: .discardRecording)
        XCTAssertNil(settings.hotkeyConflictError)

        // Carbon would refuse the second registration and leave one shortcut
        // silently dead, so the assignment is rejected up front instead.
        settings.setHotkey(.default, for: .discardRecording)
        XCTAssertEqual(settings.discardHotkey, .discardDefault)
        XCTAssertNotNil(settings.hotkeyConflictError)
        XCTAssertTrue(settings.hotkeyConflictError?.contains("toggle recording") ?? false)
    }

    @MainActor
    func testHotkeyDisplayStringForDefaultShortcut() {
        XCTAssertEqual(AppSettings.HotkeyCombo.default.displayString, "⇧⌘R")
    }

    @MainActor
    func testHotkeyDisplayStringUsesFallbackForUnknownKeyCode() {
        let combo = AppSettings.HotkeyCombo(keyCode: 255, modifiers: 0x100000)
        XCTAssertEqual(combo.displayString, "⌘?")
    }

    @MainActor
    func testHotkeyRequiresCommandControlOrOptionModifier() {
        XCTAssertTrue(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x100000).isUsableGlobalShortcut)
        XCTAssertTrue(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x40000).isUsableGlobalShortcut)
        XCTAssertTrue(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x80000).isUsableGlobalShortcut)
        XCTAssertTrue(AppSettings.HotkeyCombo.default.isUsableGlobalShortcut)
    }

    @MainActor
    func testHotkeyRejectsShiftOnlyShortcut() {
        XCTAssertFalse(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0x20000).isUsableGlobalShortcut)
        XCTAssertFalse(AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0).isUsableGlobalShortcut)
    }

    @MainActor
    func testHotkeyRecorderDecisionCancelsOnEscape() {
        XCTAssertEqual(
            HotkeyRecorderLogic.decision(keyCode: KeyCode.escape, modifierFlags: []),
            .cancel
        )
    }

    @MainActor
    func testHotkeyRecorderDecisionPassesThroughPlainKeys() {
        XCTAssertEqual(
            HotkeyRecorderLogic.decision(keyCode: KeyCode.r, modifierFlags: []),
            .passThrough
        )
    }

    @MainActor
    func testHotkeyRecorderDecisionRejectsShiftOnlyShortcut() {
        XCTAssertEqual(
            HotkeyRecorderLogic.decision(keyCode: KeyCode.r, modifierFlags: [.shift]),
            .reject
        )
    }

    @MainActor
    func testHotkeyRecorderDecisionRecordsUsableShortcutWithMaskedModifiers() {
        XCTAssertEqual(
            HotkeyRecorderLogic.decision(keyCode: KeyCode.r, modifierFlags: [.command, .shift, .capsLock]),
            .record(keyCode: KeyCode.r, modifiers: 0x120000)
        )
    }

    @MainActor
    func testFrameRateSanitizationUsesSafeFallback() {
        XCTAssertEqual(AppSettings.sanitizedFrameRate(0), 30)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(30), 30)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(60), 60)
        XCTAssertEqual(AppSettings.sanitizedFrameRate(45), 30)
        XCTAssertEqual(AppSettings.defaultFrameRate, 30)
    }

    func testGitInfoURLValidation() {
        XCTAssertNotNil(GitInfo.commitURL(for: "abc1234"))
        XCTAssertNil(GitInfo.commitURL(for: "dev"))
        XCTAssertNil(GitInfo.commitURL(for: ""))
        XCTAssertNil(GitInfo.commitURL(for: "zzzzzzzz"))
        XCTAssertNil(GitInfo.commitURL(for: "   dev   \n"))
    }

    func testGitInfoNormalizesWhitespaceBeforeValidation() {
        let url = GitInfo.commitURL(for: "   deadbeef   ")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://github.com/rselbach/reel/commit/deadbeef")
    }

    func testScreenCapturePrivacySettingsLinkTargetsExpectedPane() {
        let url = SystemSettingsLink.screenCapturePrivacy
        XCTAssertEqual(url?.scheme, "x-apple.systempreferences")
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testPermissionMenuTextMatchesExpectedActions() {
        XCTAssertEqual(AppMenuText.screenRecordingPermissionRequired, "Screen Recording Permission Required")
        XCTAssertEqual(AppMenuText.openSystemSettings, "Open System Settings...")
        XCTAssertEqual(AppMenuText.checkPermission, "Check Permission")
        XCTAssertEqual(AppMenuText.unableToOpenSettings, "Unable to open settings")
        XCTAssertEqual(AppMenuText.failedToOpenPrivacySettings, "Failed to open system privacy settings.")
        XCTAssertEqual(AppMenuText.couldNotOpenSystemPreferences, "Could not open System Preferences.")
    }

    func testAppMenuTextMatchesRecordingAndStandardMenuItems() {
        XCTAssertEqual(AppMenuText.startRecording, "Start Recording...")
        XCTAssertEqual(AppMenuText.recordingInProgress, "● Recording...")
        XCTAssertEqual(AppMenuText.stopRecording, "Stop Recording")
        XCTAssertEqual(AppMenuText.aboutReel, "About Reel")
        XCTAssertEqual(AppMenuText.settings, "Settings...")
        XCTAssertEqual(AppMenuText.quitReel, "Quit Reel")
        XCTAssertEqual(AppMenuText.hotkeyError, "Hotkey Error")
    }

    func testAppMenuTextMatchesWindowTitlesAndPreviewWarnings() {
        XCTAssertEqual(AppMenuText.recordingPreviewTitle, "Recording Preview")
        XCTAssertEqual(AppMenuText.newRecordingTitle, "New Recording")
        XCTAssertEqual(AppMenuText.settingsWindowTitle, "Reel Settings")
        XCTAssertEqual(AppMenuText.couldNotRevealRecording, "Could not reveal recording")
        XCTAssertEqual(AppMenuText.couldNotDeleteRecording, "Could not move recording to Trash")
    }

    func testPostRecordingTextMatchesPreviewActions() {
        XCTAssertEqual(PostRecordingText.loading, "Loading...")
        XCTAssertEqual(PostRecordingText.revealInFinder, "Reveal in Finder")
        XCTAssertEqual(PostRecordingText.delete, "Move to Trash")
        XCTAssertEqual(PostRecordingText.saveTrimmed, "Save Trimmed...")
        XCTAssertEqual(PostRecordingText.done, "Done")
        XCTAssertEqual(PostRecordingText.recordAgain, "Record Again")
        XCTAssertEqual(PostRecordingText.changeTarget, "Change Target...")
        XCTAssertEqual(PostRecordingText.deleteConfirmationTitle, "Move recording to Trash?")
        XCTAssertEqual(PostRecordingText.deleteConfirmationMessage, "You can recover it from the Trash.")
    }

    func testSettingsTextMatchesGeneralRecordingAndShortcutControls() {
        XCTAssertEqual(SettingsText.generalTab, "General")
        XCTAssertEqual(SettingsText.recordingTab, "Recording")
        XCTAssertEqual(SettingsText.shortcutsTab, "Shortcuts")
        XCTAssertEqual(SettingsText.launchAtLogin, "Launch at login")
        XCTAssertEqual(SettingsText.saveRecordingsTo, "Save recordings to:")
        XCTAssertEqual(SettingsText.askEachTime, "Ask each time")
        XCTAssertEqual(SettingsText.fixedFolder, "Fixed folder")
        XCTAssertEqual(SettingsText.outputDirectoryNotWritable, "Cannot write to selected folder. Pick another location.")
        XCTAssertEqual(SettingsText.recordAudio, "Record audio")
        XCTAssertEqual(SettingsText.recordCamera, "Record camera overlay")
        XCTAssertEqual(SettingsText.addTextOverlay, "Add text overlay")
        XCTAssertEqual(SettingsText.defaultDevice, "Default")
        XCTAssertEqual(SettingsText.unavailableDevice, "Unavailable device")
        XCTAssertEqual(SettingsText.pressShortcut, "Press shortcut...")
    }

    @MainActor
    func testWelcomeTextPairsTheRelaunchNoteWithAnAction() {
        XCTAssertTrue(WelcomeText.relaunchNote.contains("relaunching Reel"))
        XCTAssertEqual(WelcomeText.relaunchNow, "Relaunch Reel")
        XCTAssertEqual(WelcomeText.relaunchFailedTitle, "Could not relaunch Reel")
    }

    @MainActor
    func testSettingsWindowIsTallEnoughForTheRecordingTab() {
        // The Recording tab is the tallest: 6 always-visible controls, 3
        // dividers, and up to 9 more rows once camera and text overlay are on.
        // Scrolling covers the overflow, but the common case should still fit.
        XCTAssertGreaterThanOrEqual(SettingsLayout.height, 480)
        XCTAssertEqual(SettingsLayout.width, 460)
    }

    @MainActor
    func testSettingsErrorTextMatchesLaunchAtLoginFailure() {
        XCTAssertEqual(SettingsErrorText.launchAtLoginUpdateFailed, "Failed to update launch at login")
    }

    func testSparkleInfoPlistConfigurationIsPresent() throws {
        let plist = try loadSourceInfoPlist()
        XCTAssertEqual(plist["SUFeedURL"] as? String, "https://rselbach.github.io/reel/appcast.xml")
        let publicKey = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertFalse(publicKey.isEmpty)
        XCTAssertNotEqual(publicKey, "SPARKLE_PUBLIC_KEY_PLACEHOLDER")
        XCTAssertEqual(AppMenuText.checkForUpdates, "Check for Updates...")
    }

    func testInfoPlistDeclaresMenuBarAppAndPermissionUsageDescriptions() throws {
        let plist = try loadSourceInfoPlist()

        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.rselbach.reel")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Reel")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")

        let microphoneUsage = try XCTUnwrap(plist["NSMicrophoneUsageDescription"] as? String)
        let cameraUsage = try XCTUnwrap(plist["NSCameraUsageDescription"] as? String)
        let screenUsage = try XCTUnwrap(plist["NSScreenCaptureUsageDescription"] as? String)
        XCTAssertFalse(microphoneUsage.isEmpty)
        XCTAssertFalse(cameraUsage.isEmpty)
        XCTAssertFalse(screenUsage.isEmpty)
    }

    func testEntitlementsAllowConfiguredAudioCameraAndHardenedRuntime() throws {
        let entitlements = try loadPropertyList(at: repoRoot().appendingPathComponent("Reel.entitlements"))

        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.device.camera"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.hardened-runtime"] as? Bool, true)
    }

    func testPackageManifestPinsMacOSPlatformAndSparkleDependency() throws {
        let manifest = try String(
            contentsOf: repoRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains(".macOS(.v26)"))
        XCTAssertTrue(manifest.contains("https://github.com/sparkle-project/Sparkle"))
        XCTAssertTrue(manifest.contains(".product(name: \"Sparkle\", package: \"Sparkle\")"))
        XCTAssertTrue(manifest.contains("exclude: [\"Info.plist\", \"AppIcon.icns\"]"))
    }

    func testReleaseWorkflowFetchesHistoryForChangelog() throws {
        let workflow = try String(
            contentsOf: repoRoot().appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("fetch-depth: 0"))
    }

    func testReleaseTagValidatorRequiresNumericSemanticVersion() throws {
        let script = repoRoot().appendingPathComponent("scripts/release/validate-release-tag.sh")

        let valid = try runProcess("/bin/bash", [script.path(), "1.2.3"])
        XCTAssertEqual(valid.exitCode, 0)
        XCTAssertEqual(valid.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1.2.3")

        for version in ["not-a-version", "1..2", "1_2", "1.2.3.4", "1.2.3-beta_1", "1.2.3;false"] {
            let invalid = try runProcess("/bin/bash", [script.path(), version])
            XCTAssertNotEqual(invalid.exitCode, 0, version)
            XCTAssertTrue(invalid.stderr.contains("Expected X.Y.Z"), version)
        }
    }

    func testGenerateAppcastWritesSanitizedVersionAndSignedEnclosure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("appcast.xml")
        let script = repoRoot().appendingPathComponent("scripts/release/generate-appcast.sh")
        let signature = #"sparkle:edSignature="abc123" length="42""#

        let result = try runProcess("/bin/bash", [script.path(), "1.2.3", signature, outputURL.path()])
        XCTAssertEqual(result.exitCode, 0, result.stdout + result.stderr)

        let appcast = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(appcast.contains("<title>Version 1.2.3</title>"))
        XCTAssertTrue(appcast.contains("<sparkle:version>1.2.3</sparkle:version>"))
        XCTAssertTrue(appcast.contains(#"url="https://github.com/rselbach/reel/releases/download/v1.2.3/Reel.dmg""#))
        XCTAssertTrue(appcast.contains(signature))
    }

    func testAboutGitHubRepositoryLinkTargetsProject() {
        XCTAssertEqual(AboutLinks.githubRepository?.absoluteString, "https://github.com/rselbach/reel")
    }

    func testRecordingDialogDisplayTitles() {
        XCTAssertEqual(RecordingDialogLogic.displayTitle(index: 0, displayCount: 1), "Display")
        XCTAssertEqual(RecordingDialogLogic.displayTitle(index: 0, displayCount: 2), "Display 1")
        XCTAssertEqual(RecordingDialogLogic.displayTitle(index: 1, displayCount: 2), "Display 2")
    }

    func testRecordingSelectionUsesStableDisplayID() {
        XCTAssertEqual(RecordingSelection.display(10), .display(10))
        XCTAssertNotEqual(RecordingSelection.display(10), .display(20))
    }

    func testRecordingDialogWindowTitleFallbacks() {
        XCTAssertEqual(
            RecordingDialogLogic.windowTitle(appName: "Safari", windowTitle: "Apple"),
            "Apple — Safari"
        )
        XCTAssertEqual(
            RecordingDialogLogic.windowTitle(appName: "Safari", windowTitle: "Safari"),
            "Safari"
        )
        XCTAssertEqual(
            RecordingDialogLogic.windowTitle(appName: nil, windowTitle: nil),
            "Unknown"
        )
        XCTAssertEqual(
            RecordingDialogText.recordAudio(source: .microphone),
            "Microphone"
        )
        XCTAssertEqual(
            RecordingDialogText.recordAudio(source: .systemAudio),
            "System Audio"
        )
    }

    @MainActor
    func testRecordingCuesUseDistinctAvailableSystemSounds() {
        XCTAssertNotEqual(RecordingCue.start.soundName, RecordingCue.stop.soundName)
        XCTAssertNotNil(NSSound(named: RecordingCue.start.soundName))
        XCTAssertNotNil(NSSound(named: RecordingCue.stop.soundName))
    }

    @MainActor
    func testWindowTrackingPollsFastEnoughToLookAttached() {
        // Anything slower than a few frames reads as the overlay lagging
        // behind the window rather than being attached to it.
        XCTAssertLessThanOrEqual(WindowTracking.interval, 1.0 / 10)
        XCTAssertGreaterThan(WindowTracking.interval, 0)
    }

    @MainActor
    func testQuickRecordSummaryNamesEachTargetKind() {
        XCTAssertEqual(
            QuickRecordSummary.text(
                mode: .display,
                displayLabel: "Display 2",
                windowLabel: nil,
                regionOutputSize: nil
            ),
            "Shortcut records: Display 2"
        )
        XCTAssertEqual(
            QuickRecordSummary.text(
                mode: .window,
                displayLabel: nil,
                windowLabel: "Spanish 101",
                regionOutputSize: nil
            ),
            "Shortcut records: Spanish 101"
        )
        XCTAssertEqual(
            QuickRecordSummary.text(
                mode: .region,
                displayLabel: nil,
                windowLabel: nil,
                regionOutputSize: CGSize(width: 1280, height: 720)
            ),
            "Shortcut records: Area (1280 × 720 px)"
        )
    }

    @MainActor
    func testQuickRecordSummaryIsAbsentWithoutATarget() {
        // Nothing selected means the shortcut opens the picker, so promising
        // a target would be a lie.
        XCTAssertNil(
            QuickRecordSummary.text(
                mode: .display,
                displayLabel: nil,
                windowLabel: nil,
                regionOutputSize: nil
            )
        )
        XCTAssertNil(
            QuickRecordSummary.text(
                mode: .window,
                displayLabel: "Display 1",
                windowLabel: nil,
                regionOutputSize: nil
            )
        )
        XCTAssertNil(
            QuickRecordSummary.text(
                mode: .region,
                displayLabel: nil,
                windowLabel: nil,
                regionOutputSize: nil
            )
        )
    }

    @MainActor
    func testLastAreaLabelNamesTheRememberedSize() {
        XCTAssertEqual(
            RecordingDialogLogic.lastAreaLabel(size: CGSize(width: 1280, height: 720)),
            "Use Last Area (1280 × 720 px)"
        )
        XCTAssertEqual(
            RecordingDialogLogic.lastAreaLabel(size: CGSize(width: 640.4, height: 360.6)),
            "Use Last Area (640 × 361 px)"
        )
    }

    @MainActor
    func testDrawingAnAreaIsDistinctFromReusingOne() {
        XCTAssertNotEqual(RecordingSelection.region, RecordingSelection.lastRegion)
        XCTAssertEqual(RecordingSelection.lastRegion, RecordingSelection.lastRegion)
    }

    @MainActor
    func testPickerColumnCountMatchesTheAdaptiveGrid() {
        // 508pt of usable width at a 160pt minimum and 12pt spacing fits three.
        XCTAssertEqual(
            PickerNavigation.columnCount(availableWidth: 508, minimum: 160, spacing: 12),
            3
        )
        XCTAssertEqual(
            PickerNavigation.columnCount(availableWidth: 160, minimum: 160, spacing: 12),
            1
        )
        // Degenerate inputs still yield a usable step.
        XCTAssertEqual(PickerNavigation.columnCount(availableWidth: 0, minimum: 160, spacing: 12), 1)
        XCTAssertEqual(PickerNavigation.columnCount(availableWidth: 508, minimum: 0, spacing: 12), 1)
    }

    @MainActor
    func testArrowKeysStepByOneAndByRowWithoutWrapping() {
        XCTAssertEqual(
            PickerNavigation.nextIndex(from: nil, direction: .right, count: 9, columns: 3),
            0,
            "the first arrow press selects the first visible card"
        )
        XCTAssertEqual(
            PickerNavigation.nextIndex(from: 0, direction: .right, count: 9, columns: 3),
            1
        )
        XCTAssertEqual(
            PickerNavigation.nextIndex(from: 4, direction: .down, count: 9, columns: 3),
            7
        )
        XCTAssertEqual(
            PickerNavigation.nextIndex(from: 4, direction: .up, count: 9, columns: 3),
            1
        )

        // Clamped at both ends: holding an arrow settles rather than cycling.
        XCTAssertEqual(
            PickerNavigation.nextIndex(from: 0, direction: .left, count: 9, columns: 3),
            0
        )
        XCTAssertEqual(
            PickerNavigation.nextIndex(from: 8, direction: .down, count: 9, columns: 3),
            8
        )
        XCTAssertEqual(
            PickerNavigation.nextIndex(from: 0, direction: .right, count: 0, columns: 3),
            0
        )
    }

    @MainActor
    func testPickerPreselectionDropsTargetsThatAreGone() {
        XCTAssertEqual(
            RecordingDialogLogic.validPreselection(
                .display(3),
                displayIDs: [1, 3],
                windowIDs: []
            ),
            .display(3)
        )
        XCTAssertNil(
            RecordingDialogLogic.validPreselection(
                .display(9),
                displayIDs: [1, 3],
                windowIDs: []
            )
        )
        XCTAssertEqual(
            RecordingDialogLogic.validPreselection(
                .region,
                displayIDs: [],
                windowIDs: []
            ),
            .region
        )
        XCTAssertNil(
            RecordingDialogLogic.validPreselection(
                nil,
                displayIDs: [1],
                windowIDs: [2]
            )
        )
    }

    @MainActor
    func testRecordingDialogTextDistinguishesEmptyStates() {
        XCTAssertEqual(RecordingDialogText.noWindows, "No open windows found.")
        XCTAssertEqual(RecordingDialogText.noSearchResults, "No windows match your search.")
        XCTAssertEqual(
            RecordingDialogText.nothingRecordable,
            "No recordable displays or windows found"
        )
        XCTAssertNotEqual(
            RecordingDialogText.noWindows,
            RecordingDialogText.nothingRecordable
        )
        XCTAssertEqual(RecordingDialogText.openSystemSettings, AppMenuText.openSystemSettings)
    }

    @MainActor
    func testRecordingDialogWindowSearchMatchesAppOrTitleCaseInsensitively() {
        XCTAssertTrue(RecordingDialogLogic.windowMatchesSearch(
            appName: "Safari",
            windowTitle: "Apple Developer",
            query: "saf"
        ))
        XCTAssertTrue(RecordingDialogLogic.windowMatchesSearch(
            appName: "Safari",
            windowTitle: "Apple Developer",
            query: "developer"
        ))
        XCTAssertFalse(RecordingDialogLogic.windowMatchesSearch(
            appName: "Safari",
            windowTitle: "Apple Developer",
            query: "notes"
        ))
        XCTAssertTrue(RecordingDialogLogic.windowMatchesSearch(
            appName: nil,
            windowTitle: nil,
            query: ""
        ))
    }

    func testWindowOrderingGroupsAppsThenSortsTitles() {
        XCTAssertTrue(WindowOrdering.precedes(
            appName: "Finder",
            title: "Downloads",
            windowID: 2,
            appName: "Safari",
            title: "Greendale",
            windowID: 1
        ))
        XCTAssertTrue(WindowOrdering.precedes(
            appName: "Safari",
            title: "Greendale",
            windowID: 2,
            appName: "Safari",
            title: "Spanish 101",
            windowID: 1
        ))
        XCTAssertTrue(WindowOrdering.precedes(
            appName: "Safari",
            title: "Greendale",
            windowID: 1,
            appName: "Safari",
            title: "Greendale",
            windowID: 2
        ))
    }

    func testThumbnailLoadingUsesBoundedBatches() {
        XCTAssertEqual(
            ThumbnailLoading.batches(count: 14),
            [0..<6, 6..<12, 12..<14]
        )
        XCTAssertTrue(ThumbnailLoading.batches(count: 0).isEmpty)
    }

    func testCountdownLayoutBuildsSequenceAndCentersHUD() {
        XCTAssertEqual(CountdownLayout.sequence(duration: 3), [3, 2, 1])
        XCTAssertEqual(CountdownLayout.sequence(duration: 5), [5, 4, 3, 2, 1])
        XCTAssertEqual(CountdownLayout.sequence(duration: 0), [])

        let frame = CountdownLayout.hudFrame(referenceFrame: CGRect(x: 50, y: 75, width: 1200, height: 800))
        XCTAssertEqual(frame.midX, 650)
        XCTAssertEqual(frame.midY, 475)
        XCTAssertEqual(frame.width, CountdownLayout.hudSize)
        XCTAssertEqual(frame.height, CountdownLayout.hudSize)
    }

    @MainActor
    func testCountdownCancelHintNamesTheRecordingShortcut() {
        XCTAssertEqual(
            CountdownLayout.cancelHint(shortcut: "⇧⌘R"),
            "Click or press ⇧⌘R to cancel"
        )
        XCTAssertFalse(CountdownLayout.cancelHint(shortcut: "⇧⌘R").contains("Esc"))
    }

    @MainActor
    func testCountdownDurationSanitizationAllowsOnlySupportedValues() {
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(0), 0)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(3), 3)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(5), 5)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(10), 10)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(7), 3)
        XCTAssertEqual(AppSettings.sanitizedCountdownDuration(-1), 3)
    }

    @MainActor
    func testCameraSizeFractionSanitizationAndPresetMatching() {
        XCTAssertEqual(AppSettings.sanitizedCameraSizeFraction(0.01), CameraOverlayResizeLogic.minFraction)
        XCTAssertEqual(AppSettings.sanitizedCameraSizeFraction(0.9), CameraOverlayResizeLogic.maxFraction)
        XCTAssertEqual(AppSettings.sanitizedCameraSizeFraction(0.2), 0.2)

        let settings = AppSettings.shared
        let old = settings.cameraSizeFraction
        defer { settings.cameraSizeFraction = old }

        settings.cameraSizeFraction = 0.25
        XCTAssertEqual(settings.cameraSizePreset, .large)

        settings.cameraSizeFraction = 0.31
        XCTAssertNil(settings.cameraSizePreset)
    }

    func testCameraOverlayResizeCornerHitDetection() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertEqual(CameraOverlayResizeLogic.corner(at: CGPoint(x: 5, y: 5), in: bounds), .bottomLeft)
        XCTAssertEqual(CameraOverlayResizeLogic.corner(at: CGPoint(x: 195, y: 5), in: bounds), .bottomRight)
        XCTAssertEqual(CameraOverlayResizeLogic.corner(at: CGPoint(x: 5, y: 195), in: bounds), .topLeft)
        XCTAssertEqual(CameraOverlayResizeLogic.corner(at: CGPoint(x: 195, y: 195), in: bounds), .topRight)
        // Center and edge midpoints move rather than resize
        XCTAssertNil(CameraOverlayResizeLogic.corner(at: CGPoint(x: 100, y: 100), in: bounds))
        XCTAssertNil(CameraOverlayResizeLogic.corner(at: CGPoint(x: 100, y: 5), in: bounds))
        // Bounds smaller than two hit regions: everything is ambiguous, so move
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 20)
        XCTAssertNil(CameraOverlayResizeLogic.corner(at: CGPoint(x: 10, y: 10), in: tiny))
    }

    func testCameraOverlayResizeAnchorsOppositeCornerAndClamps() {
        let initial = CGRect(x: 100, y: 100, width: 100, height: 100)

        // Dragging the top-right corner outward grows the square while the
        // bottom-left corner stays fixed; the dominant axis (x) wins.
        let grown = CameraOverlayResizeLogic.resizedFrame(
            corner: .topRight, initialFrame: initial,
            deltaX: 40, deltaY: 10, minSide: 50, maxSide: 300
        )
        XCTAssertEqual(grown, CGRect(x: 100, y: 100, width: 140, height: 140))

        // Dragging the bottom-left corner keeps the top-right corner fixed.
        let fromBottomLeft = CameraOverlayResizeLogic.resizedFrame(
            corner: .bottomLeft, initialFrame: initial,
            deltaX: -40, deltaY: 10, minSide: 50, maxSide: 300
        )
        XCTAssertEqual(fromBottomLeft.maxX, 200)
        XCTAssertEqual(fromBottomLeft.maxY, 200)
        XCTAssertEqual(fromBottomLeft.width, 140)

        let clamped = CameraOverlayResizeLogic.resizedFrame(
            corner: .topRight, initialFrame: initial,
            deltaX: 500, deltaY: 0, minSide: 50, maxSide: 150
        )
        XCTAssertEqual(clamped.width, 150)

        let shrunk = CameraOverlayResizeLogic.resizedFrame(
            corner: .topRight, initialFrame: initial,
            deltaX: -90, deltaY: 0, minSide: 50, maxSide: 300
        )
        XCTAssertEqual(shrunk.width, 50)
    }

    @MainActor
    func testCameraOverlayLayoutConvertsNormalizedPositionToScreenOrigin() {
        let bounds = CGRect(x: 100, y: 200, width: 1000, height: 500)
        let origin = CameraOverlayLayout.originFromNormalized(
            x: 1,
            y: 0,
            overlaySize: 200,
            bounds: bounds
        )

        XCTAssertEqual(origin.x, 900)
        XCTAssertEqual(origin.y, 200)
    }

    @MainActor
    func testCameraOverlayLayoutCapsSizeToShortCaptureBounds() {
        XCTAssertEqual(
            CameraOverlayLayout.overlaySize(
                sizeFraction: 0.2,
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 500)
            ),
            200
        )
        XCTAssertEqual(
            CameraOverlayLayout.overlaySize(
                sizeFraction: 0.2,
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 100)
            ),
            100
        )
    }

    @MainActor
    func testCameraOverlayLayoutRoundTripsDraggedPosition() throws {
        let bounds = CGRect(x: 100, y: 200, width: 1000, height: 500)
        let origin = CGPoint(x: 500, y: 350)
        let position = try XCTUnwrap(CameraOverlayLayout.normalizedPosition(
            origin: origin,
            overlaySize: 200,
            bounds: bounds
        ))

        let roundTripOrigin = CameraOverlayLayout.originFromNormalized(
            x: position.x,
            y: position.y,
            overlaySize: 200,
            bounds: bounds
        )

        XCTAssertEqual(roundTripOrigin.x, origin.x, accuracy: 0.001)
        XCTAssertEqual(roundTripOrigin.y, origin.y, accuracy: 0.001)
    }

    @MainActor
    func testCameraOverlayLayoutRejectsOversizedOverlayForNormalization() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(CameraOverlayLayout.normalizedPosition(
            origin: .zero,
            overlaySize: 100,
            bounds: bounds
        ))
    }

    @MainActor
    func testActiveTextOverlayTrimsWhitespaceAndRequiresEnabledText() {
        let settings = AppSettings.shared
        let oldEnabled = settings.textOverlayEnabled
        let oldText = settings.textOverlayText
        defer {
            settings.textOverlayEnabled = oldEnabled
            settings.textOverlayText = oldText
        }

        settings.textOverlayEnabled = false
        settings.textOverlayText = " Hello "
        XCTAssertNil(settings.activeTextOverlayText)

        settings.textOverlayEnabled = true
        settings.textOverlayText = "   "
        XCTAssertNil(settings.activeTextOverlayText)

        settings.textOverlayText = " Hello "
        XCTAssertEqual(settings.activeTextOverlayText, "Hello")
    }

    @MainActor
    func testGitInfoNormalizesUppercaseCommits() {
        let uppercase = "ABCDEF1234567890"
        XCTAssertEqual(GitInfo.normalizedCommit(uppercase), uppercase.lowercased())
        XCTAssertEqual(GitInfo.commitURL(for: uppercase)?.absoluteString, "https://github.com/rselbach/reel/commit/abcdef1234567890")
    }

    @MainActor
    func testGitInfoAcceptsFullSHA() {
        // A git SHA is exactly 40 hex chars; the previous value was 42 and
        // was correctly rejected by isValidCommitSHA, failing the test.
        let fullSHA = "0123456789abcdefabcdef0123456789abcdef01"
        XCTAssertEqual(GitInfo.normalizedCommit(fullSHA), fullSHA.lowercased())
    }

    func testRecentRecordingsDeduplicateAndCapMostRecentFirst() {
        XCTAssertEqual(
            RecentRecordingsLogic.updatedPaths(current: [], adding: "/a.mp4", limit: 5),
            ["/a.mp4"]
        )
        XCTAssertEqual(
            RecentRecordingsLogic.updatedPaths(current: ["/a.mp4", "/b.mp4"], adding: "/b.mp4", limit: 5),
            ["/b.mp4", "/a.mp4"]
        )
        XCTAssertEqual(
            RecentRecordingsLogic.updatedPaths(
                current: ["/1.mp4", "/2.mp4", "/3.mp4", "/4.mp4", "/5.mp4"],
                adding: "/6.mp4",
                limit: 5
            ),
            ["/6.mp4", "/1.mp4", "/2.mp4", "/3.mp4", "/4.mp4"]
        )
        XCTAssertEqual(
            RecentRecordingsLogic.removingPath(
                "/2.mp4",
                from: ["/1.mp4", "/2.mp4", "/3.mp4"]
            ),
            ["/1.mp4", "/3.mp4"]
        )
    }

    func testRegionMathConvertsCocoaSelectionToQuartz() {
        let quartz = RegionMath.quartzRect(
            fromScreenLocalCocoa: CGRect(x: 100, y: 100, width: 400, height: 200),
            screenHeight: 900
        )
        XCTAssertEqual(quartz, CGRect(x: 100, y: 600, width: 400, height: 200))
    }

    func testRegionMathPlacesRegionInGlobalQuartzSpace() {
        let global = RegionMath.globalQuartzFrame(
            regionRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            displayFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        )
        XCTAssertEqual(global, CGRect(x: 1450, y: 20, width: 300, height: 200))
    }

    func testScreenCoordinateConversionHandlesDisplayAbovePrimary() {
        let primaryFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let upperDisplayQuartzFrame = CGRect(x: 0, y: -1080, width: 1920, height: 1080)

        XCTAssertEqual(
            ScreenCoordinateConversion.cocoaRect(
                fromQuartz: upperDisplayQuartzFrame,
                primaryScreenFrame: primaryFrame
            ),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        )
    }

    func testScreenCoordinateConversionHandlesDisplayBelowPrimary() {
        let primaryFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let lowerDisplayQuartzFrame = CGRect(x: 0, y: 1080, width: 1920, height: 1080)

        XCTAssertEqual(
            ScreenCoordinateConversion.cocoaRect(
                fromQuartz: lowerDisplayQuartzFrame,
                primaryScreenFrame: primaryFrame
            ),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        )
    }

    func testCameraCompositeSquareCropCentersOnLongAxis() {
        let landscape = CameraCompositeLayout.squareCropRect(width: 1920, height: 1080)
        XCTAssertEqual(landscape, CGRect(x: 420, y: 0, width: 1080, height: 1080))

        let portrait = CameraCompositeLayout.squareCropRect(width: 1080, height: 1920)
        XCTAssertEqual(portrait, CGRect(x: 0, y: 420, width: 1080, height: 1080))

        let square = CameraCompositeLayout.squareCropRect(width: 720, height: 720)
        XCTAssertEqual(square, CGRect(x: 0, y: 0, width: 720, height: 720))
    }

    @MainActor
    func testRecordingDimensionsStayUnchangedWhenInsideH264Limits() {
        let dimensions = ScreenRecorder.dimensionsFitting(width: 1920, height: 1080, maxSize: h264Limits)
        XCTAssertEqual(dimensions.width, 1920)
        XCTAssertEqual(dimensions.height, 1080)
    }

    @MainActor
    func testRecordingDimensionsDownscaleLargeLandscapeCaptureForH264() {
        let dimensions = ScreenRecorder.dimensionsFitting(width: 5120, height: 2880, maxSize: h264Limits)
        XCTAssertEqual(dimensions.width, 4096)
        XCTAssertEqual(dimensions.height, 2304)
    }

    @MainActor
    func testRecordingDimensionsDownscaleLargePortraitCaptureForH264() {
        let dimensions = ScreenRecorder.dimensionsFitting(width: 2880, height: 5120, maxSize: h264Limits)
        XCTAssertEqual(dimensions.width, 1296)
        XCTAssertEqual(dimensions.height, 2304)
    }

    @MainActor
    func testRecordingDimensionsLeaveInvalidValuesForExistingValidation() {
        let dimensions = ScreenRecorder.dimensionsFitting(width: 0, height: 1080, maxSize: h264Limits)
        XCTAssertEqual(dimensions.width, 0)
        XCTAssertEqual(dimensions.height, 1080)
    }

    func testRecordingFileNamingUsesReelPrefixTimestampRandomIDAndMP4Extension() {
        let date = Date(timeIntervalSince1970: 0)
        let filename = RecordingFileNaming.fileName(date: date, randomID: "ABC12345")

        XCTAssertEqual(filename, "Reel-1970-01-01T00-00-00Z-ABC12345.mp4")
        XCTAssertFalse(RecordingFileNaming.sanitizedTimestamp(from: date).contains(":"))
    }

    func testRecordingFinalizationRevealsFinderOnlyWhenPreviewIsDisabled() {
        XCTAssertTrue(RecordingFinalizationLogic.shouldRevealInFinder(
            openFinderAfterRecording: true,
            showPreviewAfterRecording: false
        ))
        XCTAssertFalse(RecordingFinalizationLogic.shouldRevealInFinder(
            openFinderAfterRecording: true,
            showPreviewAfterRecording: true
        ))
        XCTAssertFalse(RecordingFinalizationLogic.shouldRevealInFinder(
            openFinderAfterRecording: false,
            showPreviewAfterRecording: false
        ))
    }

    func testCancelledSaveKeepsTheCompletedRecordingAtItsDefaultDestination() {
        let tempURL = URL(fileURLWithPath: "/tmp/Greendale/Reel-Test.mp4")
        let selectedURL = URL(fileURLWithPath: "/tmp/Troy/Reel-Test.mp4")

        XCTAssertEqual(
            RecordingFinalizationLogic.destination(tempURL: tempURL, requestedURL: nil),
            tempURL
        )
        XCTAssertEqual(
            RecordingFinalizationLogic.destination(
                tempURL: tempURL,
                requestedURL: selectedURL
            ),
            selectedURL
        )
    }

    func testRecordingFinalizationFinderRevealFailureMessageIncludesPath() {
        let url = URL(fileURLWithPath: "/tmp/Reel-Test.mp4")
        XCTAssertEqual(
            RecordingFinalizationLogic.finderRevealFailureMessage(for: url),
            "Recording saved, but Finder could not reveal it: /tmp/Reel-Test.mp4"
        )
    }

    func testRecordingFinalizationExplainsWhereAFailedSaveWasRetained() {
        let url = URL(fileURLWithPath: "/tmp/Greendale/Reel-Test.mp4")
        let error = NSError(
            domain: "Greendale",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Destination is read-only"]
        )

        XCTAssertEqual(
            RecordingFinalizationLogic.retainedRecordingMessage(for: url, saveError: error),
            """
            Could not save to the chosen location. The recording was kept at \
            /tmp/Greendale/Reel-Test.mp4: Destination is read-only
            """
        )
    }

    func testThumbnailSizingPreservesAspectRatioWithinMaximumSize() throws {
        let landscape = try XCTUnwrap(ThumbnailSizing.targetSize(
            sourceSize: CGSize(width: 1920, height: 1080),
            maxSize: CGSize(width: 320, height: 180)
        ))
        XCTAssertEqual(landscape.width, 320)
        XCTAssertEqual(landscape.height, 180)

        let portrait = try XCTUnwrap(ThumbnailSizing.targetSize(
            sourceSize: CGSize(width: 1080, height: 1920),
            maxSize: CGSize(width: 320, height: 180)
        ))
        XCTAssertEqual(portrait.width, 101)
        XCTAssertEqual(portrait.height, 180)

        XCTAssertNil(ThumbnailSizing.targetSize(
            sourceSize: CGSize(width: 0, height: 1080),
            maxSize: CGSize(width: 320, height: 180)
        ))
    }

    func testCaptureExcludesOnlyReelsOwnApplication() {
        XCTAssertTrue(CaptureExclusionLogic.isCurrentApplication(
            bundleID: "com.rselbach.reel",
            currentBundleID: "com.rselbach.reel"
        ))
        XCTAssertFalse(CaptureExclusionLogic.isCurrentApplication(
            bundleID: "com.greendale.study",
            currentBundleID: "com.rselbach.reel"
        ))
        XCTAssertFalse(CaptureExclusionLogic.isCurrentApplication(
            bundleID: "com.rselbach.reel",
            currentBundleID: nil
        ))
    }

    func testFileReplacementMovesNewFileIntoEmptyDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tempURL = directory.appendingPathComponent("trimmed.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("new".utf8).write(to: tempURL)

        try FileReplacement.commit(tempURL: tempURL, to: outputURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path()))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "new")
    }

    func testFileReplacementReplacesExistingDestinationAfterSuccessfulMove() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tempURL = directory.appendingPathComponent("trimmed.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("old".utf8).write(to: outputURL)
        try Data("new".utf8).write(to: tempURL)

        try FileReplacement.commit(tempURL: tempURL, to: outputURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path()))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "new")
    }

    func testFileReplacementRestoresExistingDestinationWhenCommitFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingTempURL = directory.appendingPathComponent("missing.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("old".utf8).write(to: outputURL)

        XCTAssertThrowsError(try FileReplacement.commit(tempURL: missingTempURL, to: outputURL))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "old")
    }

    func testFileReplacementRemovesPartialDestinationBeforeRollback() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove test directory: \(error)")
            }
        }

        let tempURL = directory.appendingPathComponent("recording.tmp.mp4")
        let outputURL = directory.appendingPathComponent("recording.mp4")
        try Data("new".utf8).write(to: tempURL)
        try Data("old".utf8).write(to: outputURL)

        XCTAssertThrowsError(try FileReplacement.commit(
            tempURL: tempURL,
            to: outputURL,
            fileManager: PartialDestinationFailingFileManager()
        ))
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: tempURL, encoding: .utf8), "new")
    }

    func testFileReplacementReportsRollbackFailureAndPreservesBackup() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove test directory: \(error)")
            }
        }

        let missingTempURL = directory.appendingPathComponent("missing.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("old".utf8).write(to: outputURL)

        XCTAssertThrowsError(try FileReplacement.commit(
            tempURL: missingTempURL,
            to: outputURL,
            fileManager: RestoreFailingFileManager()
        )) { error in
            guard case FileReplacementError.rollbackFailed(_, _, let backupURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path()))
            let backupContents: String
            do {
                backupContents = try String(contentsOf: backupURL, encoding: .utf8)
            } catch {
                return XCTFail("Failed to read preserved backup: \(error)")
            }
            XCTAssertEqual(backupContents, "old")
        }
    }

    func testFileReplacementReportsBackupCleanupFailureAfterCommit() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove test directory: \(error)")
            }
        }

        let tempURL = directory.appendingPathComponent("trimmed.tmp.mp4")
        let outputURL = directory.appendingPathComponent("trimmed.mp4")
        try Data("old".utf8).write(to: outputURL)
        try Data("new".utf8).write(to: tempURL)

        let warning = try FileReplacement.commit(
            tempURL: tempURL,
            to: outputURL,
            fileManager: BackupCleanupFailingFileManager()
        )

        XCTAssertNotNil(warning)
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: warning?.backupURL.path() ?? ""))
    }

    func testFileReplacementAllowsAlreadyFinalDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("recording.mp4")
        try Data("final".utf8).write(to: outputURL)

        try FileReplacement.commit(tempURL: outputURL, to: outputURL)

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "final")
    }

    func testStatusItemLeftClickStopsOnlyActiveRecordings() {
        XCTAssertTrue(StatusItemClickLogic.shouldStopRecording(isRecording: true, isRightClick: false))
        XCTAssertFalse(StatusItemClickLogic.shouldStopRecording(isRecording: true, isRightClick: true))
        XCTAssertFalse(StatusItemClickLogic.shouldStopRecording(isRecording: false, isRightClick: false))
        XCTAssertFalse(StatusItemClickLogic.shouldStopRecording(isRecording: false, isRightClick: true))
    }

    func testRecordingToggleCancelsAnInFlightStartBeforeStartingAnother() {
        XCTAssertEqual(
            RecordingToggleLogic.action(isRecording: false, hasPendingStart: false),
            .start
        )
        XCTAssertEqual(
            RecordingToggleLogic.action(isRecording: false, hasPendingStart: true),
            .cancelPendingStart
        )
        XCTAssertEqual(
            RecordingToggleLogic.action(isRecording: true, hasPendingStart: true),
            .stop
        )
    }

    func testRecordingElapsedFormatCoversMinutesAndHours() {
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 0), "0:00")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 42), "0:42")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 65), "1:05")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 3600), "1:00:00")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: 3725), "1:02:05")
        XCTAssertEqual(RecordingElapsedFormat.string(seconds: -5), "0:00")
    }

    func testAppTerminationReplyDefersForActiveOrStartingRecording() {
        XCTAssertEqual(
            AppTerminationLogic.reply(
                isRecorderInitialized: false,
                isRecording: false,
                isStarting: false
            ),
            .terminateNow
        )
        XCTAssertEqual(
            AppTerminationLogic.reply(
                isRecorderInitialized: true,
                isRecording: false,
                isStarting: false
            ),
            .terminateNow
        )
        XCTAssertEqual(
            AppTerminationLogic.reply(
                isRecorderInitialized: true,
                isRecording: true,
                isStarting: false
            ),
            .terminateLater
        )
        XCTAssertEqual(
            AppTerminationLogic.reply(
                isRecorderInitialized: true,
                isRecording: false,
                isStarting: true
            ),
            .terminateLater
        )
    }

    func testCarbonModifierTranslationMapsEventMasksToCarbonMasks() {
        // Default shortcut is Cmd+Shift (0x120000)
        XCTAssertEqual(
            CarbonModifierTranslation.carbonModifiers(fromEventModifiers: 0x120000),
            UInt32(cmdKey | shiftKey)
        )
        XCTAssertEqual(
            CarbonModifierTranslation.carbonModifiers(fromEventModifiers: 0x40000),
            UInt32(controlKey)
        )
        XCTAssertEqual(
            CarbonModifierTranslation.carbonModifiers(fromEventModifiers: 0x80000),
            UInt32(optionKey)
        )
        XCTAssertEqual(CarbonModifierTranslation.carbonModifiers(fromEventModifiers: 0), 0)
    }

    func testTrimSliderMathCalculatesPositionsAndFormattedTime() {
        XCTAssertEqual(
            TrimSliderMath.startPosition(trimStart: 2, duration: 10, width: 100),
            20
        )
        XCTAssertEqual(
            TrimSliderMath.endPosition(trimEnd: 8, duration: 10, width: 100),
            80
        )
        XCTAssertEqual(
            TrimSliderMath.playheadPosition(currentTime: 5, duration: 10, width: 100),
            50
        )
        XCTAssertEqual(TrimSliderMath.formattedTime(65.4), "1:05.4")
        XCTAssertEqual(TrimSliderMath.formattedTime(.nan), "0:00.0")
        XCTAssertEqual(
            TrimSliderMath.playheadPosition(currentTime: .nan, duration: 10, width: 100),
            0
        )
        XCTAssertEqual(
            TrimSliderMath.translatedSeekTime(
                origin: 5,
                translationWidth: 20,
                usableWidth: 100,
                duration: 10
            ),
            7,
            accuracy: 0.001
        )
    }

    func testTrimSliderMathClampsSeekAndMaintainsMinimumRange() {
        XCTAssertEqual(
            TrimSliderMath.seekTime(locationX: -100, handleWidth: 12, usableWidth: 100, duration: 10),
            0
        )
        XCTAssertEqual(
            TrimSliderMath.seekTime(locationX: 500, handleWidth: 12, usableWidth: 100, duration: 10),
            10
        )
        XCTAssertEqual(
            TrimSliderMath.clampedStart(
                origin: 4.8,
                translationWidth: 100,
                usableWidth: 100,
                duration: 10,
                trimEnd: 5
            ),
            4.5
        )
        XCTAssertEqual(
            TrimSliderMath.clampedEnd(
                origin: 5.2,
                translationWidth: -100,
                usableWidth: 100,
                duration: 10,
                trimStart: 5
            ),
            5.5
        )
    }

    func testTrimSliderMathKeepsShortRecordingRangeValid() {
        XCTAssertEqual(
            TrimSliderMath.clampedStart(
                origin: 0,
                translationWidth: 100,
                usableWidth: 100,
                duration: 0.2,
                trimEnd: 0.2
            ),
            0
        )
        XCTAssertEqual(
            TrimSliderMath.clampedEnd(
                origin: 0.2,
                translationWidth: -100,
                usableWidth: 100,
                duration: 0.2,
                trimStart: 0
            ),
            0.2
        )
    }

    func testPostRecordingLogicShowsSaveTrimmedOnlyForMeaningfulTrimChanges() {
        XCTAssertFalse(PostRecordingLogic.hasTrimChanges(duration: 0, trimStart: 1, trimEnd: 5))
        XCTAssertFalse(PostRecordingLogic.hasTrimChanges(duration: 10, trimStart: 0.05, trimEnd: 9.95))
        XCTAssertTrue(PostRecordingLogic.hasTrimChanges(duration: 10, trimStart: 0.2, trimEnd: 10))
        XCTAssertTrue(PostRecordingLogic.hasTrimChanges(duration: 10, trimStart: 0, trimEnd: 9.8))
    }

    func testPostRecordingLogicExportsOnlyAValidLoadedRange() {
        XCTAssertTrue(PostRecordingLogic.canExport(
            duration: 10,
            trimStart: 0,
            trimEnd: 10,
            isExporting: false
        ))
        XCTAssertFalse(PostRecordingLogic.canExport(
            duration: 0,
            trimStart: 0,
            trimEnd: 0,
            isExporting: false
        ))
        XCTAssertFalse(PostRecordingLogic.canExport(
            duration: 10,
            trimStart: 5,
            trimEnd: 5,
            isExporting: false
        ))
        XCTAssertFalse(PostRecordingLogic.canExport(
            duration: 10,
            trimStart: 0,
            trimEnd: 10,
            isExporting: true
        ))
    }

    @MainActor
    func testTextOverlayLayoutCapsImageHeightForLongText() {
        let layout = TextOverlayLayout.imageSize(
            suggestedTextSize: CGSize(width: 1000, height: 5000),
            fontSize: 48,
            maxWidth: 1600,
            maxImageHeight: 360
        )

        XCTAssertLessThanOrEqual(layout.imageSize.height, 360)
        XCTAssertGreaterThan(layout.textRect.height, 0)
        XCTAssertLessThanOrEqual(layout.textRect.maxY, layout.imageSize.height)
    }

    @MainActor
    func testTextOverlayLayoutKeepsTopPositionVisible() {
        let yOffset = TextOverlayLayout.yOffset(
            screenHeight: 1080,
            overlayHeight: 360,
            margin: 43.2,
            position: .top
        )

        XCTAssertGreaterThanOrEqual(yOffset, 43.2)
        XCTAssertLessThanOrEqual(yOffset + 360, 1080 - 43.2)
    }

    @MainActor
    func testTextOverlayLayoutKeepsOversizedOverlayVisibleAsMuchAsPossible() {
        let yOffset = TextOverlayLayout.yOffset(
            screenHeight: 200,
            overlayHeight: 180,
            margin: 24,
            position: .center
        )

        XCTAssertEqual(yOffset, 24)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func loadSourceInfoPlist() throws -> [String: Any] {
        try loadPropertyList(at: repoRoot().appendingPathComponent("Sources/Info.plist"))
    }

    private func loadPropertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws -> (
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return (
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
