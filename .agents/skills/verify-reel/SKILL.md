---
name: verify-reel
description: Verify Reel, the macOS menu-bar screen recorder, by launching a disposable app bundle and driving its real UI with Computer Use. Use after changes to first-run, recording, settings, or preview behavior.
---

# Verify Reel

Drive the packaged Reel app as a user would. Read
[`features/README.md`](features/README.md) first, then read the file for the
feature under test.

Reel is a menu-bar macOS app. It has no CLI or HTTP interface. Use the
`computer-use:computer-use` skill and its `node_repl` workflow for every UI
action. Shell commands may build, launch, inspect, and stop the disposable
instance.

## Launch

Start from the repository root. The helper refuses to launch if any Reel
process is already running because Reel registers machine-wide hotkeys and uses
machine-wide screen, microphone, and camera permissions.

```bash
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
.agents/skills/verify-reel/scripts/verify-reel launch "${run_id}"
```

To re-sign the disposable copy after its bundle metadata changes, pass a
Developer ID Application identity:

```bash
SIGNING_IDENTITY="<Developer ID Application identity>" \
  .agents/skills/verify-reel/scripts/verify-reel launch "${run_id}"
```

`launch` runs `just build-app`, copies the result to
`.build/verify-reel/Reel Verification.app`, changes only the copied bundle's
identifier and display name, and starts its executable. It sets
`CFFIXED_USER_HOME` to the run directory, so preferences and the default Movies
folder do not touch Reel's normal data.

When `SIGNING_IDENTITY` is set, `launch` signs `Sparkle.framework`, the Reel
executable with `Reel.entitlements`, and the copied bundle in that order. The
helper verifies the copied bundle's signature before launch. It does not change
`.build/Reel.app`.

The app is ready when `launch` reports `ready`, `doctor` passes, and Computer
Use can read either the `Welcome to Reel` window or Reel's menu-bar item. The
first launch does not request screen-recording permission until the user chooses
`Grant Screen Recording Access`.

Do not start a second run. If launch reports another Reel process, leave that
process alone and ask the user to quit it.

## Permission relaunch

macOS applies a new screen-recording grant only after the requesting app quits.
Keep the current run and its signed bundle. After granting access, relaunch it
without rebuilding or signing again:

```bash
.agents/skills/verify-reel/scripts/verify-reel relaunch "${run_id}"
```

`relaunch` stops the recorded process if it is still alive, then opens the same
bundle with the same isolated home. If Reel already relaunched itself, the
helper adopts the replacement process instead. It updates the recorded PID and
runs `doctor` before returning. Do not run `cleanup` between the permission
grant and this relaunch.

## Doctor

Run this read-only check before driving the app and whenever the UI looks stale:

```bash
.agents/skills/verify-reel/scripts/verify-reel doctor "${run_id}"
```

Doctor requires the recorded PID to be alive, its command to match the copied
executable, the copied bundle ID to be `com.rselbach.reel.verification`, and the
embedded commit to match `HEAD`. It prints the app path, PID, bundle ID,
evidence directory, and current network-connection count. A failed doctor means
the instance is not safe to drive. Clean it up, then launch a new run.

## Drive

Load the `computer-use:computer-use` skill. Initialize its bundled package once
in a fresh `node_repl` session:

```js
globalThis.sky = (await import("@oai/sky")).sky;
globalThis.reelFs = await import("node:fs/promises");
globalThis.reelFileURLToPath = (await import("node:url")).fileURLToPath;
globalThis.reelRepo = nodeRepl.cwd;
globalThis.reelRunId = (
  await reelFs.readFile(
    `${reelRepo}/.build/verify-reel/current-run`,
    "utf8"
  )
).trim();
globalThis.reelRunDir =
  `${reelRepo}/.build/verify-reel/runs/${reelRunId}`;
globalThis.reelAppPath = (
  await reelFs.readFile(`${reelRunDir}/app-path`, "utf8")
).trim();
globalThis.reelEvidenceDir = (
  await reelFs.readFile(`${reelRunDir}/evidence-dir`, "utf8")
).trim();
globalThis.captureReel = async (name) => {
  const state = await sky.get_app_state({
    app: reelAppPath,
    disableDiff: true,
  });
  await reelFs.mkdir(reelEvidenceDir, { recursive: true });
  await reelFs.writeFile(
    `${reelEvidenceDir}/${name}.ax.txt`,
    `${state.text}\n`
  );
  if (!state.screenshot) {
    throw new Error(`Reel returned no screenshot for ${name}`);
  }
  await reelFs.copyFile(
    reelFileURLToPath(state.screenshot.url),
    `${reelEvidenceDir}/${name}.png`
  );
  return state;
};
globalThis.reelState = await captureReel("initial");
nodeRepl.write(reelState.text);
```

Use the full app path from the run metadata. Do not target `Reel` by display
name because a normal installation may exist on the same Mac.

Derive every `element_index` from the latest accessibility tree. After each
click, key press, drag, or value change, call `get_app_state` again before
choosing the next index. Stable handles in this app include:

- window names `Welcome to Reel`, `New Recording`, `Reel Settings`,
  `Recording Preview`, and `About Reel`
- buttons and menu items such as `Get Started`, `Start Recording...`,
  `Settings...`, `Stop Recording`, `Record Again`, and `Done`
- tabs `General`, `Recording`, and `Shortcuts`
- the menu-bar item whose accessibility description is `Reel`

Use coordinates only when the accessibility tree omits a visual control, such
as a trim handle or a recording-region corner. Capture a fresh screenshot
before choosing coordinates and another one after the action.

## Evidence

Proof belongs in `.build/verification-evidence/reel/<run-id>/`. The capture
helper writes matching `.ax.txt` and `.png` files there. Name captures after the
feature and state, for example `settings-before` and `settings-after`.

A valid proof must:

- follow a user entry point from the matching feature file
- capture the action state and the resulting state, not only the last window
- use the packaged app and normal UI rather than internal setters or test-only
  code
- confirm file or preference changes through a second read-only view
- keep production boundaries intact; use mocks only where Reel already has one
- report every mapped entry point that was skipped or blocked

For a preference side effect, capture the helper's read-only result:

```bash
.agents/skills/verify-reel/scripts/verify-reel preference \
  "${run_id}" hasShownWelcome \
  > ".build/verification-evidence/reel/${run_id}/hasShownWelcome.txt"
```

For a recording, capture the picker, the recording state, and the preview.
Also record `stat` and `mdls` output for the MP4 under the run's isolated Movies
directory. Confirm that dry-run or safe-mode claims match observed files,
network connections, and UI behavior. Do not infer safety from a label.

## Cleanup

Stop only the recorded PID, then remove the copied app and per-run state:

```bash
.agents/skills/verify-reel/scripts/verify-reel cleanup "${run_id}"
```

Cleanup verifies that the PID still belongs to the exact executable before it
sends a signal. It never kills by process name. It removes
`.build/verify-reel/Reel Verification.app` and that run's scratch directory.
It does not remove `.build/verification-evidence/reel/<run-id>/`.

After cleanup, prove that the evidence survived:

```bash
test -d ".build/verification-evidence/reel/${run_id}"
find ".build/verification-evidence/reel/${run_id}" -type f -maxdepth 1 -print
```

If a drive fails, run cleanup before retrying. If cleanup refuses because the
PID now names another executable, do not signal it. Report the mismatch.

## Helpers

The executable helper is
`.agents/skills/verify-reel/scripts/verify-reel`.

```text
verify-reel launch <run-id>
verify-reel relaunch <run-id>
verify-reel doctor <run-id>
verify-reel describe <run-id>
verify-reel preference <run-id> <key>
verify-reel cleanup <run-id>
```

`describe` prints the recorded paths and identity. `preference` reads one key
from the run's isolated defaults domain. Neither command changes app state.
