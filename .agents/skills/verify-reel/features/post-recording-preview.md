# Post-recording preview

Recording Preview plays the finished MP4 and lets the user edit, share, export,
repeat, retarget, reveal, or delete the take.

## Sub-features

- `preview-open` opens automatically after a successful take when enabled.
- `preview-copy` puts the recording file on the pasteboard.
- `preview-share` opens the system share menu for the same file.
- `preview-reveal` selects the MP4 in Finder.
- `preview-delete` confirms and moves the recording to Trash.
- `preview-edit` trims either end with handles, splits at the playhead,
  deletes or restores clips, and exports an edited copy.
- `preview-undo` undoes and redoes timeline changes.
- `preview-transport` plays and skips through edited time, the only clock.
- `preview-smaller` exports a 720p copy.
- `preview-gif` exports the edited recording as a looping GIF.
- `preview-export-cancel` stops an export and leaves no file behind.
- `preview-again` records the remembered target again.
- `preview-change-target` returns to New Recording.

## How to get to it (user POV)

- Stop a successful recording while `Show preview after recording` is enabled.

## Driving it with Computer Use

Preconditions:

- `verify-reel doctor <run-id>` passes.
- Create a short, harmless MP4 inside the run's isolated Movies directory.
- Keep `Show preview after recording` enabled.
- Record the source MP4 path and initial `stat` output before mutating anything.

- **Open state.** Stop the take and require window `Recording Preview`, the
  MP4 filename, `Undo`, `Redo`, `Back 5 seconds`, `Play`,
  `Forward 5 seconds`, `Timeline`, `Split`, `Playhead`, `Trim start`,
  `Trim end`, `Clip`, `Copy`, `Share`, `Reveal in Finder`, `Move to Trash`,
  `Record Again`, `Change Target...`, menu button `Export`, and `Done`. No
  text may mention `Source` time. Capture `preview-open`.
- **Transport.** Click `Play`. Require the control to change to `Pause` and the
  edited playback time to advance. Use `Back 5 seconds` and `Forward 5 seconds`.
  Require both controls to change edited time and skip removed sections.
- **Copy.** Click `Copy`. Require the button to read `Copied!`. Inspect the
  pasteboard through a read-only local command and require a file URL equal to
  the source MP4. Do not paste it into another app for proof.
- **Share.** Click `Share` and require the system share popover. Press Escape
  to dismiss it. Never pick a sharing service.
- **Reveal.** Click `Reveal in Finder`. Require Finder to show the source MP4
  selected. This changes foreground app state but does not alter the file.
- **Trim.** Drag `Trim start` inward. Require a `Deleted clip` at the start,
  the video to show the frame under the handle while dragging, and the
  edited time's total to shrink. Drag it back out and require the footage to
  return. Repeat with `Trim end`.
- **Edit.** Drag the `Playhead` by its knob, then click `Split` and require a
  new `Clip` boundary at the playhead. Move the playhead and press Command-B.
  Select the middle `Clip`, select another clip, then press Delete. Require
  only the second clip to become a red `Deleted clip`, with `Restore Clip`.
  Restore it, then delete the middle clip. Choose `Export`, then
  `Edited Video...`, and save inside the isolated Movies directory. Require a
  second nonzero MP4 whose duration matches the kept clips, the file chip to
  name it, and `Copy` and `Share` to be enabled.
- **Undo.** Press Command-Z until `Undo` is disabled, requiring each press to
  step back one change. Press Shift-Command-Z once and require the last undone
  change to return. Drag a zoom scene's focus twice with a pause between and
  require each drag to undo separately. Trim again, open the `Edit` menu in
  Reel's menu bar, require `Undo` enabled, choose it, and require the trim to
  return.
- **Windows.** While the preview is open, require Reel in the Dock and
  Command-Tab with `Reel`, `Edit`, and `Window` menus. Start another take with
  the global shortcut and require the second preview 24 points right of and
  below the first. Close both and require Reel to leave the Dock.
- **Smaller copy.** Choose `Export`, then `Smaller Copy (720p)...`, and save
  inside the isolated Movies directory. While it writes, require text
  `Exporting` with a percentage, a progress indicator, and `Cancel`. Then
  require `Saved` naming the file, a `Show in Finder` link, Finder to stay in
  the background, and a nonzero MPEG-4 file no taller than 720 pixels.
- **GIF.** Choose `Export`, then `Animated GIF...`, save inside the isolated
  Movies directory, and require a nonzero GIF no wider than 800 pixels. Open
  it in Finder preview and observe that it loops through the kept ranges.
- **Cancel.** Start an `Animated GIF...` export to a new name and press
  `Cancel` while `Exporting` shows. Require the `Export` menu to return with
  no error and no `Saved` line. Run `ls -la` on the destination and require no
  new file, including hidden partial files.
- **Change target.** Click `Change Target...` and require `New Recording` with
  no active preview window. Make a fresh recording to continue the remaining
  preview checks.
- **Record again.** Click `Record Again`. Require preview to close and the
  remembered target to enter countdown without reopening the picker. Cancel the
  countdown with Escape if this recipe is not making a second recording.
- **Delete.** Only for a disposable file created by this run, click `Move to
  Trash`. Require alert `Move recording to Trash?`. Click `Cancel` and require
  the file to remain. Repeat and confirm only when deletion is part of the test,
  then require the file to be absent from its old path and from Recent
  Recordings.
- **Proof.** Capture the source preview and each tested export result. Save
  `stat` and `mdls` output for the source and derived files.

## Gotchas

- `Move to Trash` is destructive. Computer Use requires confirmation at action
  time, and the target must be a disposable recording from this run.
- Save panels can default outside the isolated Movies directory. Verify the
  destination before confirming.
- Trim handles and the playhead knob need coordinates from their
  accessibility frames. The knob sits above the zoom lane; a drag that starts
  in the lane adds a zoom scene instead. Capture a fresh screenshot before and
  after each drag.
- `Edited Video...` is enabled only after an edit. Splits alone do not change
  the exported recording.
- Reel refuses to delete the last retained clip.
- `Record Again` can begin countdown immediately. Be ready to press Escape.
- Finder and save panels are separate apps. Return to the recorded Reel app path
  and fetch fresh state before continuing.
