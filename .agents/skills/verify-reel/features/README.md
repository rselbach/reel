# Reel verification map

This directory is the maintained source for verifying Reel's user-facing
behavior. Read this index before driving the app, then follow the matching
feature file. Reel is a menu-bar macOS app, so all recipes use Computer Use
against a disposable packaged build.

## Baseline preconditions

- Work from the Reel repository root on macOS 26 or later.
- Launch one disposable instance with the helper in `../SKILL.md`.
- Require `verify-reel doctor <run-id>` to pass before every recipe.
- Load the `computer-use:computer-use` skill and target the full app path
  recorded by the helper.
- Never drive a Reel process that this run did not start.
- Do not run beside another Reel instance. Global hotkeys and device
  permissions cannot be isolated per process.
- Treat screen, microphone, camera, Accessibility, and launch-at-login
  permissions as shared machine state. Do not grant or revoke them without the
  user's approval.

## Driving conventions

- Start each recipe from a fresh run unless its preconditions say otherwise.
- Read a fresh accessibility tree after every UI action.
- Prefer accessible names, window titles, and menu-item titles over coordinates.
- Use screenshots only to choose coordinates for controls missing from the
  accessibility tree.
- Keep all recordings under the run's isolated `Movies` directory.
- Restore changed settings before cleanup when the recipe calls for it.
- Leave proof artifacts in `.build/verification-evidence/reel/<run-id>/`.

## Proof and skip reporting

- Capture each visible action and result state as both accessibility text and a
  screenshot.
- When the expected result has no app window, pair the action screenshot with
  doctor output and a read-only preference or file check.
- Confirm preference changes with `verify-reel preference` and recordings with
  `stat` and `mdls`.
- Record the feature ID and entry point in artifact names or a short text file.
- Report permission-dependent paths as blocked when the required permission is
  absent. Do not grant permission silently.
- Do not report one entry point as proof for another skipped entry point.
- A successful internal unit test is supporting evidence, not user-path proof.

## Feature entry contract

Each feature file has an H1, one user-facing summary paragraph, and exactly four
H2 sections in this order.

1. `Sub-features` lists the behaviors covered by the file.
2. `How to get to it (user POV)` lists every supported user entry point.
3. `Driving it with Computer Use` pairs UI actions with accessible names and
   observable results.
4. `Gotchas` names traps that can invalidate a run.

## Features

- [First launch](./first-launch.md) covers the welcome window, menu-bar and
  shortcut explanations, permission explanation, and persisted dismissal.
- [Choose a recording target](./choose-recording-target.md) covers display,
  window, and area entry points, refresh, search, and per-take device toggles.
- [Recording lifecycle](./recording-lifecycle.md) covers countdown, active,
  pause, resume, stop, discard, and quick re-record paths.
- [Settings](./settings.md) covers General, Recording, and Shortcuts settings
  and persistence.
- [Post-recording preview](./post-recording-preview.md) covers preview, copy,
  reveal, delete, trim, smaller-copy, GIF, and target selection paths.
