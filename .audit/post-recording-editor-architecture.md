# Post-recording editor architecture

## Problem

The preview currently exposes AVPlayer's scrubber and a second custom timeline.
The custom timeline compresses endpoint trims, removed sections, selection, and
the playhead into a 50-point bar. `TimelineEdit` already owns the right media
invariants. The change should replace the interaction layer without creating a
second edit model.

## Usage

`AppDelegate` keeps the existing `PostRecordingView` initializer and owns window
actions. `PostRecordingView` owns the player, the current `TimelineEdit`, and
export actions.

```swift
PlayerSurface(player: player)
PlaybackTransport(
    intent: playbackIntent,
    currentTime: editedCurrentTime,
    duration: edit.editedDuration,
    onTogglePlayback: togglePlayback,
    onSkip: skipEditedSeconds
)
PostRecordingTimelineView(
    videoURL: videoURL,
    edit: $edit,
    currentSourceTime: currentSourceTime,
    selection: $timelineSelection,
    onSeek: seekPlayer
)
```

The player surface hides native controls. The custom transport and filmstrip are
the only playback controls.

## Shape

`TimelineEdit` remains the only media edit model. It continues to separate
endpoint trims from normalized interior cuts and derive kept ranges for playback,
MP4 export, and GIF sampling.

```swift
enum TimelineSelection: Equatable {
    case none
    case range(TimelineSpan)
    case cut(TimelineCut.ID)
}

enum PlaybackIntent: Equatable {
    case paused
    case playing
}
```

`TimelineSelection` prevents a pending range and selected cut from coexisting.
`PlaybackIntent` describes the user's command. It does not claim that AVPlayer is
currently rendering while it buffers.

The timeline stays in source-time coordinates because cuts and trims locate
original media. The transport converts the current source time through
`TimelineEdit.editedTime(forSourceTime:)` and shows edited duration. Five-second
skips also work in edited time and map back to source time before seeking.

A click seeks. A drag selects a range. The range remains visible until the user
cuts it or clears it. A successful cut becomes the selected cut and can be
restored immediately. Existing cuts remain selectable. Invalid edits keep the
model unchanged and show a user-facing failure.

The filmstrip samples the original asset at a quantized count derived from its
width. Resizing starts a cancellable replacement task only when that count
changes. Trimmed regions are dimmed. Removed ranges use a hatch and label in
addition to color. Thumbnail images do not enter `TimelineEdit`.

Pure timeline math owns time-to-position conversion, range width, thumbnail
sample times, and edited-time skip targets. `TimelineEdit` remains the only place
that validates minimum retained duration and normalizes cuts.

The module map is small.

```text
PostRecordingView.swift
  player lifecycle, playback intent, editor layout, file and export actions
PostRecordingTimelineView.swift
  filmstrip rendering, gestures, accessibility, thumbnails, pure layout math
PostRecordingTimeline.swift
  unchanged canonical edit model
VideoEditExporter.swift
  unchanged kept-range consumer
```

Space toggles playback. The visible skip buttons move five edited seconds.
Timeline handles expose adjustable accessibility actions. Removed sections are
focusable buttons with source ranges and a restore hint. A newly cut section
receives accessibility focus so the reversible result is immediate.

## Synthesis decision

Candidate A is the base. It kept runtime ownership flat and put the timeline in
one focused child module. Candidate C supplied focus handoff after a cut and
explicit observer, MP4-path, and GIF-mapping verification. Candidate B's session
object lost because it republished `TimelineEdit`, duplicated transport values,
and exposed pass-through commands without hiding enough complexity.

The cross-judge scorecard ranked Candidate A at 34/35, Candidate C at 30/35,
and Candidate B at 24/35.

The synthesized design drops Candidate A's manual filmstrip-height grip. The
filmstrip responds to window width and uses a readable fixed height. This removes
layout state that the request does not need.

## Tradeoffs accepted

- We accept several local SwiftUI state values in exchange for one obvious owner.
- We accept source-time geometry beside an edited-time clock in exchange for
  stable cut positions and an honest output duration.
- We accept one new internal UI file in exchange for removing timeline drawing
  and thumbnail work from an already large view.
- We accept thumbnail regeneration at quantized width changes in exchange for a
  sharp filmstrip without a cache service.
- We keep edit state ephemeral. Closing the window still preserves the original
  recording and discards edits that were not exported.

## Verification contract

- Pure tests cover geometry, range selection, sampling, and edited-time skips.
- Existing timeline and real MP4 splice tests remain green.
- The packaged app shows one transport, a thumbnail filmstrip, clear trims, range
  selection, cutting, restoration, resizing, and unchanged export actions.
- Playback crosses cut boundaries and pauses at the end trim.
- The disposable bundle uses the fixed verification identifier and the supplied
  Developer ID identity before launch.
