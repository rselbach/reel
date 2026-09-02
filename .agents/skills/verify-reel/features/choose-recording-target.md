# Choose a recording target

The New Recording window lets a user choose a display, window, new area, or
remembered area and set microphone or camera use for only the next take.

## Sub-features

- `picker-open` opens a fresh New Recording window from the status menu.
- `picker-display` selects or double-clicks a display card.
- `picker-window` searches, selects, or double-clicks a window card.
- `picker-area` starts a new adjustable region selection.
- `picker-last-area` reuses the most recently recorded region.
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
  Require the window `New Recording` and heading `Select what to record`.
- **Initial state.** On a fresh run, require `Start Recording` to be disabled
  until a target is selected. Capture `picker-initial`.
- **Display selection.** Click the button named `Display`, or `Display 1` when
  several displays exist. Require the card to gain the selected trait and
  `Start Recording` to become enabled.
- **Window search.** Set the `Search` text field to a non-sensitive window title.
  Require unmatched window cards to disappear. Set it to a missing value and
  require `No windows match your search.` Clear the field before continuing.
- **Refresh.** Click the button whose help text is `Refresh displays and
  windows`. Wait for loading to finish, then require the selected source to
  remain only if it still exists.
- **Per-take overrides.** Toggle `Microphone` and `Camera` under `For this
  recording`. Capture the changed controls. Open Settings after cancelling and
  require the saved `Record audio` and `Record camera overlay` values to be
  unchanged.
- **Cancel.** Click `Cancel`. Require `New Recording` to close. Reopen it from
  the status menu and require a fresh picker window.
- **Area entry.** Click `Select Area to Record...`. Require the full-screen
  region overlay. Draw a harmless region, require corner handles and a pixel
  readout, move or resize it, then press Escape. Require no recording file.
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
- `Use Last Area (...)` appears only after Reel has remembered a valid region.
- Global shortcuts are machine-wide and may require Accessibility permission.
  Do not grant it silently.
