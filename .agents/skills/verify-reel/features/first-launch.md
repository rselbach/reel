# First launch

First launch explains why Reel has no Dock window, shows the global recording
shortcut, names the required permission, and remembers when the user dismisses
the welcome window.

## Sub-features

- `first-launch-welcome` opens the welcome window on fresh preferences.
- `first-launch-menu-bar-explainer` tells the user where Reel lives.
- `first-launch-shortcut` shows the current recording shortcut.
- `first-launch-permission-explainer` names screen-recording access without
  requesting it automatically.
- `first-launch-dismiss` closes the welcome window and remembers the choice.

## How to get to it (user POV)

- Launch Reel with fresh preferences.
- Choose `Get Started` in the `Welcome to Reel` window.

## Driving it with Computer Use

Preconditions:

- Start a fresh verification run. Its isolated preferences must not contain
  `hasShownWelcome`.
- `verify-reel doctor <run-id>` passes.
- Do not click `Grant Screen Recording Access` in this recipe.

- **Welcome state.** Capture `first-launch-before`. Require a window named
  `Welcome to Reel`, text explaining that Reel lives in the menu bar, the
  current shortcut, the screen-recording permission explanation, and buttons
  named `Grant Screen Recording Access` and `Get Started`.
- **No unsolicited prompt.** Before clicking either button, require that the
  accessibility tree contains no macOS screen-recording permission dialog.
- **Dismiss.** Click the current element whose accessible name is `Get Started`.
  Fetch a fresh tree. The app now has no window, and some Computer Use backends
  report a no-window timeout. Do not use that timeout as proof by itself.
- **Result.** Run `verify-reel doctor <run-id>` and require the process to remain
  healthy. Run `verify-reel preference <run-id> hasShownWelcome` and require
  `1`. Save those outputs as `doctor-after.txt` and `hasShownWelcome.txt` in the
  evidence directory.
- **Proof.** Keep `first-launch-before.ax.txt`, `first-launch-before.png`,
  `doctor-after.txt`, and `hasShownWelcome.txt`. Together they show the action
  state, the closed-window process state, and the persisted result.

## Gotchas

- The verification app uses a separate bundle ID, so its permission state can
  differ from the installed Reel app.
- After granting access, use `verify-reel relaunch <run-id>` and continue the
  same run. Rebuilding or cleaning up before relaunching breaks the grant flow.
- Closing the welcome window with its title-bar close button also sets
  `hasShownWelcome`; use `Get Started` for this recipe.
- `Get Started` does not grant permission. It only closes the welcome window.
- The menu-bar item is not part of an app-window screenshot. Verify status-menu
  behavior through the feature recipe that led to it, not this first-run proof.
