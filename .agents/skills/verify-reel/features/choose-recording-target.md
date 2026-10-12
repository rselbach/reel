# Choose a recording target

The New Recording window lets a user choose a display, window, new area, or
remembered area and set microphone or camera use for only the next take.

## Sub-features

- `picker-open` opens a fresh New Recording window from the status menu.
- `picker-switcher` shows displays, windows, or areas, one tab at a time.
- `picker-display` selects or double-clicks a display card named as System
  Settings names the display.
- `picker-window` searches, selects, or double-clicks a window card.
- `picker-area` picks `New Area` and starts an adjustable region selection.
- `picker-last-area` picks `Last Area (...)` to reuse the remembered region.
- `picker-keyboard` moves between cards with the arrow keys.
- `picker-refresh` reloads recordable displays and windows.
- `picker-empty` explains missing sources and links to System Settings.
- `picker-overrides` changes microphone and camera for one take only.

## How to get to it (user POV)

- Choose Reel's menu-bar item, then `Start Recording...`.
- Press the configured global recording shortcut when no remembered target is
  usable.
- Choose `Change Target...` from Recording Preview.
- Choose `Record Again` when the remembered target is unavailable.

## Driving it with Computer Use

Preconditions:

- `verify-reel doctor <run-id>` passes.
- Dismiss the first-launch window.
- Screen-recording permission is effective for the verification bundle. If it
  is absent, report the source-selection paths as blocked.
- Keep at least one harmless window open for window selection. Do not expose
  private content in screenshots or recordings.

- **Open picker.** Click the `Reel` menu-bar item, then `Start Recording...`.
  Require the window `New Recording`, centered on its screen, with a radio
  group `Record` holding segments `Display`, `Window`, and `Area`. Capture
  `picker-initial`.
- **Display tab.** Click segment `Display`. Require one card per display,
  named as System Settings names it, such as `Built-in Retina Display`, with
  the main display selected and `Start Recording` enabled.
- **Window tab.** Click segment `Window`. On a fresh run, require `Start
  Recording` to be disabled until a window card is selected. Set the `Search`
  text field to a non-sensitive window title. Require unmatched window cards
  to disappear. Set it to a missing value and require `No windows match your
  search.` Clear the field before continuing.
- **Keyboard.** Click a card, then press the arrow keys. Require left and right
  to move one card and up and down to move one row, without wrapping.
- **Area tab.** Click segment `Area`. Require `New Area` selected and the main
  button to read `Select Area...`. After an area take, require `Last Area (...)`
  with the remembered size, selected when the picker reopens, and the main
  button to read `Start Recording`.
- **Refresh.** Click the button whose help text is `Refresh displays and
  windows`. Wait for loading to finish, then require the selected source to
  remain only if it still exists.
- **Per-take overrides.** Toggle `Microphone` and `Camera` under `For this
  recording`. Capture the changed controls. Open Settings after cancelling and
  require the saved `Record audio` and `Record camera overlay` values to be
  unchanged.
- **Cancel.** Require `Cancel` directly left of the main button. Click it and
  require `New Recording` to close. Reopen it from the status menu and require
  a fresh picker window.
- **Area entry.** On the Area tab with `New Area` selected, click `Select
  Area...`. Require the full-screen region overlay. Draw a harmless region,
  require corner handles and a pixel readout, move or resize it, then press
  Escape. Require no recording file.
- **Proof.** Capture `picker-selected` with the chosen card, enabled Start
  button, and per-take toggles visible. If the recipe starts a take, continue
  with `recording-lifecycle.md` and prove the resulting MP4.

## Gotchas

- Thumbnails contain live screen contents. Arrange harmless windows before
  capture and review evidence for sensitive information.
- The refresh button may expose only its help text in Accessibility.
- A double-click starts immediately and skips the enabled-button state. Use a
  single click when proving selection.
- Pressing Return in the region overlay starts recording. Escape cancels.
- `Last Area (...)` appears only after Reel has remembered a valid region.
- With one display, the menu's quick-record item reads `Record Entire Screen`;
  with several, it names the display.
- Global shortcuts are machine-wide and may require Accessibility permission.
  Do not grant it silently.
