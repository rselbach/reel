import CoreMedia
import Foundation
import XCTest

@testable import Reel

final class CaptureEngineTests: XCTestCase {
    func testAudioSampleTimingDropsBuffersBeforeSessionStart() {
        let sessionStart = CMTime(value: 10_000, timescale: 1_000)
        let earlyPTS = CMTime(value: 9_990, timescale: 1_000)
        let duration = CMTime(value: 20, timescale: 1_000)

        XCTAssertNil(
            AudioSampleTiming.nextOutputEndTime(
                presentationTime: earlyPTS,
                duration: duration,
                sessionStartTime: sessionStart,
                lastPresentationTime: nil,
                lastOutputEndTime: nil
            )
        )
    }

    func testAudioSampleTimingAcceptsContiguousBuffersAndRejectsOverlap() {
        let sessionStart = CMTime(value: 10_000, timescale: 1_000)
        let duration = CMTime(value: 20, timescale: 1_000)

        let firstPTS = sessionStart
        let firstEnd = AudioSampleTiming.nextOutputEndTime(
            presentationTime: firstPTS,
            duration: duration,
            sessionStartTime: sessionStart,
            lastPresentationTime: nil,
            lastOutputEndTime: nil
        )
        XCTAssertEqual(firstEnd, CMTime(value: 10_020, timescale: 1_000))

        // Overlapping after pause/resume: starts after firstPTS, before firstEnd.
        let overlappingPTS = CMTime(value: 10_010, timescale: 1_000)
        XCTAssertNil(
            AudioSampleTiming.nextOutputEndTime(
                presentationTime: overlappingPTS,
                duration: duration,
                sessionStartTime: sessionStart,
                lastPresentationTime: firstPTS,
                lastOutputEndTime: firstEnd
            )
        )

        // Exact contiguous boundary is accepted.
        let contiguousPTS = CMTime(value: 10_020, timescale: 1_000)
        let secondEnd = AudioSampleTiming.nextOutputEndTime(
            presentationTime: contiguousPTS,
            duration: duration,
            sessionStartTime: sessionStart,
            lastPresentationTime: firstPTS,
            lastOutputEndTime: firstEnd
        )
        XCTAssertEqual(secondEnd, CMTime(value: 10_040, timescale: 1_000))
    }

    func testAudioSampleTimingRejectsDuplicateTimestampWithZeroOrInvalidDuration() {
        let sessionStart = CMTime(value: 10_000, timescale: 1_000)
        let firstEnd = AudioSampleTiming.nextOutputEndTime(
            presentationTime: sessionStart,
            duration: .invalid,
            sessionStartTime: sessionStart,
            lastPresentationTime: nil,
            lastOutputEndTime: nil
        )
        XCTAssertEqual(firstEnd, sessionStart)

        XCTAssertNil(
            AudioSampleTiming.nextOutputEndTime(
                presentationTime: sessionStart,
                duration: .zero,
                sessionStartTime: sessionStart,
                lastPresentationTime: sessionStart,
                lastOutputEndTime: firstEnd
            )
        )

        let advancingPTS = CMTime(value: 10_001, timescale: 1_000)
        XCTAssertEqual(
            AudioSampleTiming.nextOutputEndTime(
                presentationTime: advancingPTS,
                duration: .invalid,
                sessionStartTime: sessionStart,
                lastPresentationTime: sessionStart,
                lastOutputEndTime: firstEnd
            ),
            advancingPTS
        )
    }

    func testAudioSampleTimingRejectsInvalidPresentationTime() {
        let sessionStart = CMTime(value: 10_000, timescale: 1_000)
        XCTAssertNil(
            AudioSampleTiming.nextOutputEndTime(
                presentationTime: .invalid,
                duration: CMTime(value: 20, timescale: 1_000),
                sessionStartTime: sessionStart,
                lastPresentationTime: nil,
                lastOutputEndTime: nil
            )
        )
    }

    @MainActor
    func testCountdownCameraOverlayPositionAndSizeSurviveRecordingStart() {
        let recorder = ScreenRecorder()
        var options = RecordingOptions(settings: AppSettings.shared)
        options.recordCamera = true
        options.cameraPosition = .bottomRight
        options.cameraSizeFraction = 0.2

        recorder.beginCountdownCameraPreviewLayout(
            position: options.cameraPosition,
            sizeFraction: options.cameraSizeFraction
        )
        recorder.updateCameraOverlayPosition(x: 0.25, y: 0.75)
        recorder.updateCameraOverlaySize(fraction: 0.30)

        recorder.applyCameraLayoutForRecordingStart(options: options)

        let layout = recorder.currentCameraOverlayLayout
        XCTAssertEqual(layout.x, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(layout.y, 0.75, accuracy: 0.000_1)
        XCTAssertEqual(layout.sizeFraction, 0.30, accuracy: 0.000_1)
    }

    @MainActor
    func testFreshRecordingStartUsesOptionsCameraOverlayLayout() {
        let recorder = ScreenRecorder()
        var options = RecordingOptions(settings: AppSettings.shared)
        options.recordCamera = true
        options.cameraPosition = .topLeft
        options.cameraSizeFraction = 0.25

        // Even if a previous countdown was dragged and then discarded, a fresh
        // recording without countdown preview resets to options.
        recorder.beginCountdownCameraPreviewLayout(position: .bottomRight, sizeFraction: 0.2)
        recorder.updateCameraOverlayPosition(x: 0.6, y: 0.4)
        recorder.updateCameraOverlaySize(fraction: 0.32)
        recorder.discardCameraPreview()

        recorder.applyCameraLayoutForRecordingStart(options: options)

        let expected = AppSettings.CameraOverlayPosition.topLeft.normalizedCoordinates
        let layout = recorder.currentCameraOverlayLayout
        XCTAssertEqual(layout.x, expected.x, accuracy: 0.000_1)
        XCTAssertEqual(layout.y, expected.y, accuracy: 0.000_1)
        XCTAssertEqual(layout.sizeFraction, 0.25, accuracy: 0.000_1)
    }

    @MainActor
    func testStaleWriteFailureCallbackDoesNotOverwriteCurrentSessionError() async {
        let recorder = ScreenRecorder()
        let firstSession = recorder.advanceRecordingSessionID()
        let secondSession = recorder.advanceRecordingSessionID()
        XCTAssertGreaterThan(secondSession, firstSession)

        await recorder.stopAfterWriteFailure(
            sessionID: firstSession,
            context: "Stale take 1",
            reason: "Late callback"
        )
        XCTAssertNil(recorder.errorMessage)

        await recorder.stopAfterWriteFailure(
            sessionID: secondSession,
            context: "Current take 2",
            reason: "Disk full"
        )
        XCTAssertEqual(recorder.errorMessage, "Current take 2: Disk full")
    }

    func testFileReplacementCommitTreatsSymlinkedSameFileAsNoOp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-greendale-symlink-\(UUID().uuidString)")
        let realDir = root.appendingPathComponent("real")
        let linkDir = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: root)
            }
        }
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let realFile = realDir.appendingPathComponent("troy-take.mp4")
        let symlinkedFile = linkDir.appendingPathComponent("troy-take.mp4")
        let payload = Data("greendale-recording".utf8)
        try payload.write(to: realFile)

        let warning = try FileReplacement.commit(tempURL: realFile, to: symlinkedFile)
        XCTAssertNil(warning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realFile.path(percentEncoded: false)))
        XCTAssertEqual(try Data(contentsOf: realFile), payload)
    }

    func testAvailableCapacityWalksUpToNearestExistingAncestor() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-missing-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("study-room")

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path(percentEncoded: false)))
        let capacity = RecordingFileStore.availableCapacity(at: missingDirectory)
        let bytes = try XCTUnwrap(capacity)
        XCTAssertGreaterThan(bytes, 0)
    }

    func testAudioLevelScaleSelectsLoudestFiniteChannel() {
        XCTAssertEqual(AudioLevelScale.normalized(channelDecibels: []), 0)
        XCTAssertEqual(AudioLevelScale.normalized(channelDecibels: [-.infinity, .nan]), 0)
        // Channel 1 silent/unplugged, channel 2 active (-12 dB -> 0.8).
        XCTAssertEqual(
            AudioLevelScale.normalized(channelDecibels: [-.infinity, -12]),
            0.8,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            AudioLevelScale.normalized(channelDecibels: [-54, -6, -30]),
            0.9,
            accuracy: 0.000_1
        )
    }
}
