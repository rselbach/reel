# Post-recording preview

Recording Preview plays the finished MP4 and lets the user edit, share, export,
repeat, retarget, reveal, or delete the take.

## Sub-features

- `preview-open` opens automatically after a successful take when enabled.
- `preview-copy` puts the recording file on the pasteboard.
- `preview-reveal` selects the MP4 in Finder.
- `preview-delete` confirms and moves the recording to Trash.
- `preview-edit` splits at the playhead, deletes or restores clips, and saves
  an edited copy.
- `preview-transport` plays and skips through edited time.
- `preview-smaller` exports a 720p copy.
- `preview-gif` exports the edited recording as a looping GIF.
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
  MP4 filename, `Back 5 seconds`, `Play`, `Forward 5 seconds`, `Timeline`,
  `Playhead`, `Clip`, `Copy`, `Reveal in Finder`, `Move to Trash`,
  `Record Again`, `Change Target...`, `Smaller Copy...`, `GIF...`, and
  `Done`. Capture `preview-open`.
- **Transport.** Click `Play`. Require the control to change to `Pause` and the
  edited playback time to advance. Use `Back 5 seconds` and `Forward 5 seconds`.
  Require both controls to change edited time and skip removed sections.
- **Copy.** Click `Copy`. Require the button to read `Copied!`. Inspect the
  pasteboard through a read-only local command and require a file URL equal to
  the source MP4. Do not paste it into another app for proof.
- **Reveal.** Click `Reveal in Finder`. Require Finder to show the source MP4
  selected. This changes foreground app state but does not alter the file.
- **Edit.** Drag the `Playhead`, right-click the timeline, and require `Split
  Clip at Playhead`. Split twice, select the middle `Clip`, and click `Delete
  Clip`. Require a red `Deleted clip`, `Restore Clip`, `Save Edited...`,
  and the edit note. Restore it, then delete it again. Delete a first or last
  clip and require the same controls so endpoint trimming uses the same model.
  Save inside the isolated Movies directory. Require a second nonzero MP4 whose
  duration matches the kept clips.
- **Smaller copy.** Click `Smaller Copy...`, save inside the isolated Movies
  directory, and require a nonzero MPEG-4 file no taller than 720 pixels.
- **GIF.** Click `GIF...`, save inside the isolated Movies directory, and
  require a nonzero GIF no wider than 800 pixels. Open it in Finder preview and
  observe that it loops through the kept ranges.
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
- Dragging a source range may require coordinates even though `Source timeline`
  appears in the accessibility tree. Capture a fresh screenshot before and
  after the drag.
- `Save Edited...` appears only after a clip is deleted. Splits alone do not
  change the exported recording.
- Reel refuses to delete the last retained clip.
- `Record Again` can begin countdown immediately. Be ready to press Escape.
- Finder and save panels are separate apps. Return to the recorded Reel app path
  and fetch fresh state before continuing.
