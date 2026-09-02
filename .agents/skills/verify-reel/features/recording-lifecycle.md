# Recording lifecycle

Reel counts down, records the chosen target, shows live pause and elapsed state,
and lets the user stop or discard the take from the menu or global shortcuts.

## Sub-features

- `record-countdown` delays capture for the configured duration.
- `record-active` shows recording state and elapsed time in the menu bar.
- `record-pause` pauses writing while keeping the capture session alive.
- `record-resume` resumes without adding the paused interval to the file.
- `record-stop` finalizes a playable MP4.
- `record-discard` confirms menu discard and writes no finished file.
- `record-shortcuts` starts, stops, pauses, and discards through configured keys.
- `record-quick-start` reuses the last valid target.

## How to get to it (user POV)

- Select a source in `New Recording`, then choose `Start Recording`.
- Double-click a display or window card.
- Confirm a selected area with Return or a double-click.
- Press the configured recording shortcut for a remembered target.
- While recording, left-click Reel's menu-bar item to stop immediately.
- Right-click the menu-bar item to open pause, stop, and discard controls.

## Driving it with Computer Use

Preconditions:

- `verify-reel doctor <run-id>` passes.
- Screen-recording permission is effective and a harmless target is selected.
- General settings use `Fixed folder`, point inside the run's isolated Movies
  directory, and keep `Show preview after recording` on.
- Microphone and camera are off unless the recipe is explicitly testing them.
- Record a disposable window with no sensitive content.

- **Before state.** Save a recursive file listing of the isolated Movies
  directory as `recording-files-before.txt`.
- **Countdown.** Choose `Start Recording`. Require the countdown overlay to show
  each configured number and allow Escape to cancel. After cancellation,
  require no new MP4.
- **Active state.** Start again and wait for the start cue. Right-click the
  `Reel` menu-bar item so it opens rather than stops. Require `Recording...`,
  `Pause Recording`, `Stop Recording`, and `Discard Recording`. Capture
  `recording-active`.
- **Pause and resume.** Click `Pause Recording`. Reopen the menu and require
  `Paused` and `Resume Recording`. Wait long enough to see that elapsed time
  does not advance. Click `Resume Recording` and require elapsed time to
  advance again.
- **Stop.** Either click `Stop Recording` in the menu or left-click the status
  item. Require a `Recording Preview` window when preview is enabled.
- **File proof.** Find the new MP4 only under the isolated Movies directory.
  Save `stat` and `mdls` output. Require a nonzero file size, MPEG-4 content
  type, and a playable duration. Play it in Preview and check that the paused
  interval is absent.
- **Discard.** Start another take, choose `Discard Recording`, and require the
  alert `Discard this recording?`. Click `Cancel` and require recording to
  continue. Repeat, click `Discard`, and require no new MP4 or recent-recording
  entry.
- **Shortcut entries.** Test each configured global shortcut separately only
  when Accessibility permission is already available. Capture the same active,
  paused, resumed, stopped, or discarded end state for each entry.

## Gotchas

- A normal left-click stops an active recording. Use a right-click when opening
  its menu for pause, resume, or discard.
- Screen, microphone, camera, and Accessibility permission dialogs are system
  state. Pause and ask before changing them.
- Start and stop cues can enter a microphone recording if the machine routes
  speaker output back into the selected input. Keep audio off for baseline runs.
- A preview window is not enough proof. Inspect the MP4 and play it.
- Discard is destructive by design. Use only files created inside this run.
- Quitting during a take finalizes it. Do not use process termination to test
  discard.
