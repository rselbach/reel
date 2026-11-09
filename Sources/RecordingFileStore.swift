import Foundation
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel",
    category: "RecordingFileStore"
)

enum RecordingFileNaming {
    /// Named the way macOS names its own screen recordings, in local time
    /// and the user's 12- or 24-hour clock: "Reel 2026-10-11 at 7.58.07 PM.mp4".
    /// Finder names cannot hold colons, so the time uses periods, as macOS
    /// does. A second take in the same second gets " (2)", and so on.
    static func fileName(
        date: Date,
        copy: Int = 1,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"

        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.setLocalizedDateFormatFromTemplate("jms")
        // Plain spaces: some locales put a narrow no-break space before
        // "PM", which is hard to type in a terminal.
        let clock = time.string(from: date)
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        let suffix = copy > 1 ? " (\(copy))" : ""
        return "Reel \(day.string(from: date)) at \(clock)\(suffix).mp4"
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
            Not enough free space in \(directory.path(percentEncoded: false)) to record. \
            \(free) available, about \(seconds)s at the current video quality. \
            Free up space or lower the video quality in Settings.
            """
    }
}

enum RecordingError: LocalizedError {
    case outputDirectoryCreationFailed(URL, Error)
    case outputDirectoryNotWritable(URL)

    var errorDescription: String? {
        switch self {
        case .outputDirectoryCreationFailed(let url, let error):
            "Unable to prepare output directory \(url.path(percentEncoded: false)): \(error.localizedDescription)"
        case .outputDirectoryNotWritable(let url):
            "Output directory is not writable: \(url.path(percentEncoded: false))"
        }
    }
}

struct FileReplacementWarning: LocalizedError {
    let backupURL: URL
    let underlyingError: Error

    var errorDescription: String? {
        "The new file was saved, but its backup could not be removed at \(backupURL.path(percentEncoded: false)): \(underlyingError.localizedDescription)"
    }
}

enum FileReplacementError: LocalizedError {
    case rollbackFailed(Error, Error, URL)

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let commitError, let restoreError, let backupURL):
            return
                "Replacement failed (\(commitError.localizedDescription)), and the original file could not be restored. It remains at \(backupURL.path(percentEncoded: false)): \(restoreError.localizedDescription)"
        }
    }
}

enum FileReplacement {
    @discardableResult
    static func commit(
        tempURL: URL,
        to outputURL: URL,
        fileManager: FileManager = .default
    ) throws -> FileReplacementWarning? {
        if tempURL == outputURL {
            return nil
        }

        guard fileManager.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            try fileManager.moveItem(at: tempURL, to: outputURL)
            return nil
        }

        let backupURL =
            outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).reel-backup-\(UUID().uuidString)")

        try fileManager.moveItem(at: outputURL, to: backupURL)
        do {
            try fileManager.moveItem(at: tempURL, to: outputURL)
        } catch let commitError {
            if fileManager.fileExists(atPath: backupURL.path(percentEncoded: false)) {
                do {
                    if fileManager.fileExists(atPath: outputURL.path(percentEncoded: false)) {
                        try fileManager.removeItem(at: outputURL)
                    }
                    try fileManager.moveItem(at: backupURL, to: outputURL)
                } catch let restoreError {
                    throw FileReplacementError.rollbackFailed(
                        commitError,
                        restoreError,
                        backupURL
                    )
                }
            }
            throw commitError
        }

        do {
            try fileManager.removeItem(at: backupURL)
            return nil
        } catch {
            return FileReplacementWarning(
                backupURL: backupURL,
                underlyingError: error
            )
        }
    }
}

/// Everything Reel does to the filesystem for a recording: naming, output
/// directory validation, free space queries, and discarding temporary files.
/// Split out so the recorder owns capture rather than also owning file layout.
enum RecordingFileStore {
    /// Creates the output directory if needed, verifies it is a writable
    /// directory, and returns a unique file URL inside it.
    static func makeOutputURL(in outputDir: URL) throws -> URL {
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
                NSError(
                    domain: "ScreenRecorder", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Output path is not a directory"])
            )
        }

        if values.isWritable != true {
            throw RecordingError.outputDirectoryNotWritable(outputDir)
        }

        let date = Date()
        for copy in 1...64 {
            let candidate = outputDir.appendingPathComponent(
                RecordingFileNaming.fileName(date: date, copy: copy)
            )
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
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

    /// Free space the system is willing to give up for important user data.
    /// Returns nil when the volume cannot be queried (a missing directory,
    /// most often), which callers treat as "do not block".
    static func availableCapacity(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            logger.warning(
                "Could not read free space for \(url.path(percentEncoded: false)): \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes a temporary recording that will never reach the user.
    static func discard(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
