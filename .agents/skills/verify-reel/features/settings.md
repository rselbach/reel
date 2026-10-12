# Settings

Settings controls output behavior, capture options, device choices, overlays,
and the three global shortcuts, with changes persisted between windows.

## Sub-features

- `settings-open` opens one reusable Reel Settings window.
- `settings-general` changes save, after-recording, cue, and login behavior.
- `settings-video` changes countdown, cursor, click, and format behavior.
- `settings-audio-camera` changes audio and camera overlay behavior.
- `settings-overlays` changes window framing and text overlay behavior.
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

- **Open.** Click `Settings...`. Require window `Reel Settings` with toolbar
  buttons `General`, `Video`, `Audio & Camera`, `Overlays`, and `Shortcuts`.
  Capture `settings-general-before`.
- **After recording.** Set `When a recording ends` to `Reveal it in Finder`,
  then `Do nothing`. After each, read `showPreviewAfterRecording` and
  `openFinderAfterRecording` with `verify-reel preference`; require `0` and `1`,
  then `0` and `0`. Restore `Show the preview`. Capture
  `settings-general-after`.
- **Save choice.** Change `Save recordings to` between `Ask each time` and
  `Fixed folder`. Require the `Folder` row, showing the folder's name, and
  `Choose...` only for the fixed choice. Restore the original value.
- **Video tab.** Click `Video`. Require `Countdown`, `Show cursor in
  recording`, and `Highlight clicks` under `Capture`, and `Resolution`, `Frame
  rate`, `Codec`, and `Video quality` under `Format`, with quality choices
  `Smaller file`, `Balanced`, `High`, and `Best`. Capture `settings-video`.
- **Overlays tab.** Click `Overlays`. Turn on window framing and require
  `Background` with swatch buttons `Charcoal`, `Slate`, `Linen`, `Dusk
  (gradient)`, and `Mist (gradient)`. Click `Dusk (gradient)`, require it to be
  selected, and read `windowBackground` as `dusk`. Turn on `Add text overlay`
  and require `Text` and `Position`. Require the window to grow for each.
  Restore all values, including `Charcoal`.
- **Audio & Camera tab.** Click `Audio & Camera`. Turn on `Record camera
  overlay` and require `Camera`, `Position`, `Size`, and `Shape`. If microphone
  permission already exists, turn on `Record audio` and require `Source`,
  `Microphone`, and an `Input level` meter that reacts to sound. Restore the
  values.
- **Shortcuts tab.** Click `Shortcuts`. Require rows for `Toggle recording`,
  `Discard recording`, and `Pause and resume`, plus `Restore Default
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
- Toggles are switches with no accessible name of their own. Each sits in a
  group beside its label text, which it names as its title element. Click the
  switch in the same group as the label.
- Each tab resizes the window as its toggles reveal rows. Fetch a fresh tree
  after every toggle; element IDs and frames change.
- A picker may expose its current value as a pop-up button. Inspect the fresh
  tree before selecting a menu choice.
- Shortcut capture registers machine-wide Carbon hotkeys. Never run beside
  another Reel instance, and restore changed shortcuts before cleanup.
