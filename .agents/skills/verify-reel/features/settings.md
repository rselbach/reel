# Settings

Settings controls output behavior, capture options, device choices, overlays,
and the three global shortcuts, with changes persisted between windows.

## Sub-features

- `settings-open` opens one reusable Reel Settings window.
- `settings-general` changes save, preview, Finder, cue, and login behavior.
- `settings-recording` changes cursor, frame, video, audio, camera, and text
  overlay behavior.
- `settings-meter` shows live microphone level only for microphone capture.
- `settings-shortcuts` records three shortcuts and rejects conflicts.
- `settings-persist` restores saved values after closing and reopening.

## How to get to it (user POV)

- Choose Reel's menu-bar item, then `Settings...`.
- Press Command-comma while Reel is active.

## Driving it with Computer Use

Preconditions:

- `verify-reel doctor <run-id>` passes.
- Dismiss the first-launch window and open Reel's status menu.
- Do not toggle `Launch at login` in a baseline run because it changes a
  machine-wide login item.
- Do not enable microphone or camera unless the needed permission already
  exists or the user approves the system prompt.

- **Open.** Click `Settings...`. Require window `Reel Settings` and tabs
  `General`, `Recording`, and `Shortcuts`. Capture `settings-general-before`.
- **General dependency.** Toggle `Show preview after recording` off. Require
  `Open Finder after recording` to become enabled and the text `Finder opens
  automatically only when the preview is off.` to disappear. Toggle preview
  back on and require the inverse. Capture `settings-general-after`.
- **Save choice.** Change `Save recordings to:` between `Ask each time` and
  `Fixed folder`. Require `Output folder:` and `Choose...` only for the fixed
  choice. Restore the original value.
- **Recording tab.** Click `Recording`. Require `Show cursor in recording`,
  `Highlight clicks`, `Frame window recordings on a background`, frame rate,
  resolution, codec, quality, countdown, audio, camera, and text overlay
  controls. Capture `settings-recording`.
- **Conditional controls.** Toggle framing and require `Background:`. Toggle
  text overlay and require `Text:` and `Position:`. Restore both values.
- **Audio and camera.** If permissions already exist, toggle audio and camera
  and require their source or device controls. For microphone audio, require the
  `Input level` meter to react to sound. Restore the values.
- **Shortcuts tab.** Click `Shortcuts`. Require rows for `Start/Stop Recording`,
  `Pause/Resume Recording`, and `Discard Recording`, plus `Restore Default
  Shortcuts`. Do not type a global shortcut unless the recipe intends to change
  it and can restore it.
- **Persistence.** Close `Reel Settings`, reopen it from the menu, and require
  the final restored values. Use `verify-reel preference` to capture any value
  intentionally changed for the proof.
- **Keyboard entry.** Close the window, activate Reel, and press `super+comma`.
  Require the same `Reel Settings` window.

## Gotchas

- Launch at login is not isolated by `CFFIXED_USER_HOME`. It uses macOS service
  management and can affect the user's login items.
- Opening a device control can prompt for microphone or camera permission.
- The Recording tab scrolls when conditional camera and text controls are open.
- A picker may expose its current value as a pop-up button. Inspect the fresh
  tree before selecting a menu choice.
- Shortcut capture registers machine-wide Carbon hotkeys. Never run beside
  another Reel instance, and restore changed shortcuts before cleanup.
