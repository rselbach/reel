#!/usr/bin/env swift
import AVFoundation
import Foundation

let durationTolerance = 0.25

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: verify-edited-video.swift SOURCE.mp4 EDITED.mp4 WANTED_DURATION_SECONDS")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let editedURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let wantedDuration = Double(CommandLine.arguments[3]), wantedDuration.isFinite, wantedDuration > 0 else {
    fail("wanted duration must be a finite number greater than zero")
}

do {
    let source = AVURLAsset(url: sourceURL)
    let edited = AVURLAsset(url: editedURL)
    let durationTime = try await edited.load(.duration)
    let duration = CMTimeGetSeconds(durationTime)
    guard duration.isFinite else {
        fail("edited video duration is not finite")
    }
    guard abs(duration - wantedDuration) <= durationTolerance else {
        fail(
            "edited duration \(duration) differs from wanted duration \(wantedDuration) "
                + "by more than the \(durationTolerance)-second tolerance"
        )
    }

    let videoTracks = try await edited.loadTracks(withMediaType: .video)
    guard !videoTracks.isEmpty else {
        fail("edited file has no video track")
    }

    let sourceAudioCount = try await source.loadTracks(withMediaType: .audio).count
    if sourceAudioCount > 0 {
        let editedAudioCount = try await edited.loadTracks(withMediaType: .audio).count
        guard editedAudioCount == sourceAudioCount else {
            fail("edited file has \(editedAudioCount) audio tracks; source has \(sourceAudioCount)")
        }
    }

    print("verified edited video: duration \(duration)s, \(videoTracks.count) video track(s)")
} catch {
    fail(error.localizedDescription)
}
