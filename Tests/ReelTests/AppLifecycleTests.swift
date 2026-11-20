import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import Reel

final class AppLifecycleTests: XCTestCase {
    @MainActor
    func testPromisedRecordingCopiesOffMainActorAndOverwritesExistingPlaceholder() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-promised-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("greendale-campus-tour.mp4")
        let destinationURL = tempDir.appendingPathComponent("dropped-recording.mp4")
        let expectedData = Data("troy-and-abed-in-the-morning".utf8)
        try expectedData.write(to: sourceURL)
        try Data("stale-placeholder".utf8).write(to: destinationURL)

        let source = PreviewShareSource()
        source.fileName = { "greendale-campus-tour.mp4" }
        source.file = { sourceURL }

        let recorder = CopyThreadRecorder()
        let promise = PromisedRecording(
            source: source,
            copyFile: { src, dst in
                recorder.record(isMainThread: Thread.isMainThread)
                try PromisedRecording.replaceAndCopyItem(from: src, to: dst)
            }
        )
        let provider = NSFilePromiseProvider(fileType: UTType.mpeg4Movie.identifier, delegate: promise)

        let copyError: Error? = await withCheckedContinuation { continuation in
            promise.filePromiseProvider(provider, writePromiseTo: destinationURL) { error in
                continuation.resume(returning: error)
            }
        }

        XCTAssertNil(copyError)
        XCTAssertEqual(recorder.snapshot(), [false])
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedData)
    }

    @MainActor
    func testPreviewWindowRetainsConcurrentPromisedRecordingsUntilCompletion() async throws {
        _ = NSApplication.shared

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-concurrent-promises-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("study-room-f.mp4")
        let firstDestination = tempDir.appendingPathComponent("first-drop.mp4")
        let secondDestination = tempDir.appendingPathComponent("second-drop.mp4")
        let expectedData = Data("six-seasons-and-a-movie".utf8)
        try expectedData.write(to: sourceURL)
        try Data("existing-first".utf8).write(to: firstDestination)
        try Data("existing-second".utf8).write(to: secondDestination)

        let previewWindow = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        previewWindow.isReleasedWhenClosed = false
        previewWindow.shareSource.fileName = { "study-room-f.mp4" }
        previewWindow.shareSource.file = { sourceURL }

        let gate = ConcurrentCopyGate()
        let recorder = CopyThreadRecorder()

        weak var weakFirst: PromisedRecording?
        weak var weakSecond: PromisedRecording?

        let firstResult = await withCheckedContinuation { (firstDone: CheckedContinuation<Error?, Never>) in
            let firstCopy = previewWindow.registerPromisedRecording { src, dst in
                recorder.record(isMainThread: Thread.isMainThread)
                gate.enterFirstAndWait()
                try PromisedRecording.replaceAndCopyItem(from: src, to: dst)
            }
            weakFirst = firstCopy.promise

            let secondCopy = previewWindow.registerPromisedRecording { src, dst in
                recorder.record(isMainThread: Thread.isMainThread)
                gate.signalSecondEntered()
                try PromisedRecording.replaceAndCopyItem(from: src, to: dst)
            }
            weakSecond = secondCopy.promise

            XCTAssertEqual(previewWindow.activePromisedRecordingCount, 2)
            XCTAssertNotNil(weakFirst)
            XCTAssertNotNil(weakSecond)

            let firstProvider = NSFilePromiseProvider(
                fileType: UTType.mpeg4Movie.identifier,
                delegate: firstCopy.promise
            )
            let secondProvider = NSFilePromiseProvider(
                fileType: UTType.mpeg4Movie.identifier,
                delegate: secondCopy.promise
            )

            let group = DispatchGroup()
            let errorStore = CopyErrorStore()

            group.enter()
            firstCopy.promise.filePromiseProvider(firstProvider, writePromiseTo: firstDestination) { error in
                errorStore.setFirst(error)
                group.leave()
            }

            group.enter()
            secondCopy.promise.filePromiseProvider(secondProvider, writePromiseTo: secondDestination) { error in
                errorStore.setSecond(error)
                group.leave()
            }

            group.notify(queue: .main) {
                let (firstErr, secondErr) = errorStore.snapshot()
                firstDone.resume(returning: firstErr ?? secondErr)
            }
        }

        XCTAssertNil(firstResult)
        XCTAssertEqual(previewWindow.activePromisedRecordingCount, 0)
        XCTAssertEqual(recorder.snapshot(), [false, false])
        XCTAssertEqual(try Data(contentsOf: firstDestination), expectedData)
        XCTAssertEqual(try Data(contentsOf: secondDestination), expectedData)
    }

    @MainActor
    func testWindowWillCloseResetsPreviewWindowHandlers() async {
        _ = NSApplication.shared

        let appDelegate = AppDelegate()
        let previewWindow = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        previewWindow.isReleasedWhenClosed = false

        var undoCalled = false
        var redoCalled = false
        let sampleURL = URL(fileURLWithPath: "/tmp/greendale-clip.mp4")

        previewWindow.undoCommands.canUndo = { true }
        previewWindow.undoCommands.canRedo = { true }
        previewWindow.undoCommands.undo = { undoCalled = true }
        previewWindow.undoCommands.redo = { redoCalled = true }

        previewWindow.shareSource.readyFile = { sampleURL }
        previewWindow.shareSource.fileName = { "greendale-clip.mp4" }
        previewWindow.shareSource.file = { sampleURL }

        appDelegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: previewWindow))

        XCTAssertFalse(previewWindow.undoCommands.canUndo())
        XCTAssertFalse(previewWindow.undoCommands.canRedo())
        previewWindow.undoCommands.undo()
        previewWindow.undoCommands.redo()
        XCTAssertFalse(undoCalled)
        XCTAssertFalse(redoCalled)

        XCTAssertNil(previewWindow.shareSource.readyFile())
        XCTAssertEqual(previewWindow.shareSource.fileName(), "Recording.mp4")
        do {
            _ = try await previewWindow.shareSource.shareableFile()
            XCTFail("Expected reset shareSource.shareableFile() to throw CancellationError")
        } catch is CancellationError {
            // Expected after reset.
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRecordingStartGuardBlocksActivePendingStartingAndStoppingStates() {
        XCTAssertTrue(
            RecordingStartGuard.canStart(
                hasPendingStart: false,
                isRecording: false,
                isStarting: false,
                isStopping: false
            )
        )
        XCTAssertFalse(
            RecordingStartGuard.canStart(
                hasPendingStart: true,
                isRecording: false,
                isStarting: false,
                isStopping: false
            )
        )
        XCTAssertFalse(
            RecordingStartGuard.canStart(
                hasPendingStart: false,
                isRecording: true,
                isStarting: false,
                isStopping: false
            )
        )
        XCTAssertFalse(
            RecordingStartGuard.canStart(
                hasPendingStart: false,
                isRecording: false,
                isStarting: true,
                isStopping: false
            )
        )
        XCTAssertFalse(
            RecordingStartGuard.canStart(
                hasPendingStart: false,
                isRecording: false,
                isStarting: false,
                isStopping: true
            )
        )
    }

    func testLaunchLogicRequestsPermissionWheneverPreflightPasses() {
        XCTAssertTrue(LaunchLogic.showsWelcome(hasShownWelcome: false, hasScreenRecordingAccess: true))
        XCTAssertTrue(LaunchLogic.shouldRequestPermissionOnLaunch(hasScreenRecordingAccess: true))
        XCTAssertFalse(LaunchLogic.shouldRequestPermissionOnLaunch(hasScreenRecordingAccess: false))
    }

    func testWindowPresentationLogicOnlyReassertsTrackedVisibleWindows() {
        XCTAssertTrue(WindowPresentationLogic.shouldReassert(isTracked: true, isVisible: true))
        XCTAssertFalse(WindowPresentationLogic.shouldReassert(isTracked: false, isVisible: true))
        XCTAssertFalse(WindowPresentationLogic.shouldReassert(isTracked: true, isVisible: false))
        XCTAssertFalse(WindowPresentationLogic.shouldReassert(isTracked: false, isVisible: false))
    }
}

private final class CopyThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record(isMainThread: Bool) {
        lock.lock()
        values.append(isMainThread)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class ConcurrentCopyGate: @unchecked Sendable {
    private let secondEntered = DispatchSemaphore(value: 0)

    func enterFirstAndWait() {
        _ = secondEntered.wait(timeout: .now() + 5)
    }

    func signalSecondEntered() {
        secondEntered.signal()
    }
}

private final class CopyErrorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Error?
    private var second: Error?

    func setFirst(_ error: Error?) {
        lock.lock()
        first = error
        lock.unlock()
    }

    func setSecond(_ error: Error?) {
        lock.lock()
        second = error
        lock.unlock()
    }

    func snapshot() -> (Error?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (first, second)
    }
}
