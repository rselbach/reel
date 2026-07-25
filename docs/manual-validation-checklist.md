# Reel Manual Validation Checklist

Source of truth: `docs/feature-status.csv`.

Generated from the canonical tracker on 2026-06-21. This checklist is a companion artifact for executing the remaining manual validation pass; update the CSV after validation.

Environment note: a bounded System Events probe on 2026-06-21 returned `UI elements enabled = false`, so this environment cannot inspect the menu bar, permission prompts, device pickers, or recording UI.

Manual validation required: 34 stories.
No further manual validation required: 2 stories.

## Recommended Order

1. Permissions and device-dependent setup.
2. Recording start, countdown, active recording, stop, and termination flows.
3. Post-recording preview, trim, export, reveal, and delete flows.
4. Settings, hotkeys, launch at login, updates, and menu/about affordances.
5. Release packaging checks that are already covered by automation.

# Manual Validation Required

## US-001 - Menu bar presence

User story: As a user, I want Reel to live in the macOS menu bar so I can control recording without a main window.

Expected behavior: On launch, Reel creates a variable-length status item with the record.circle symbol and no default app window content.

Manual steps:

1. Launch .build/Reel.app
2. verify only a menu-bar status item appears with Reel icon and no main app window
3. quit from menu.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-002 - Screen recording permission gate

User story: As a first-time user, I want clear guidance when screen recording permission is missing so I can enable the app.

Expected behavior: The first-run welcome window explains the menu bar icon and the recording shortcut, then requests screen recording permission with context. When permission is not yet in effect it explains that macOS requires a relaunch and offers a Relaunch Reel button that starts a fresh instance and quits the current one; relaunch failures are surfaced in an alert. The status item menu separately offers Open System Settings and Check Permission while permission is missing.

Manual steps:

1. Launch Reel with screen recording permission revoked
2. verify the welcome window explains the permission and the relaunch requirement
3. grant access in System Settings
4. press Relaunch Reel and verify a new instance starts and the old one quits
5. verify recording works after the relaunch.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-003 - Open System Settings for screen capture

User story: As a user without permission, I want one menu action to open macOS Screen Recording privacy settings.

Expected behavior: Open System Settings uses the x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture deep link and shows an alert if opening fails. The deep-link URL is centralized in SystemSettingsLink and covered by a unit test.

Manual steps:

1. With permission missing, choose Open System Settings
2. verify System Settings opens Privacy & Security > Screen & System Audio Recording or equivalent Screen Capture pane
3. verify failure alert if URL cannot open.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-004 - Start recording from menu

User story: As a user, I want to start a recording from the menu so I can choose what to capture.

Expected behavior: If permission exists and not recording, the menu offers Start Recording. Choosing it refreshes shareable displays/windows and opens the New Recording dialog. If the dialog is closed with the title-bar close button, AppDelegate clears its window reference so it can be reopened later.

Manual steps:

1. Open Start Recording
2. close dialog with title-bar close
3. reopen from menu
4. verify a fresh New Recording dialog appears and Start is disabled until a source is selected.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-005 - Select display recording

User story: As a user, I want to select a full display so the recording captures that screen.

Expected behavior: The dialog lists available displays with thumbnails. Selecting or double-clicking a display sets recordingMode to display and selectedDisplayIndex before countdown and capture. Oversized H.264 capture dimensions are downscaled within a 4096x2304 bounding box while preserving aspect ratio.

Manual steps:

1. Record a single display and, if available, each external display
2. verify selected display is captured, file plays, and oversized displays produce valid MP4 dimensions.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-006 - Select window recording

User story: As a user, I want to select a specific window so the recording captures only that window.

Expected behavior: The dialog lists on-screen windows larger than 100x100 excluding Reel, supports search by app/title, and uses SCContentFilter(desktopIndependentWindow:) for capture. Oversized H.264 capture dimensions are downscaled within a 4096x2304 bounding box while preserving aspect ratio.

Manual steps:

1. Open window picker
2. search by app/title
3. select and double-click a window
4. verify only that window is captured and large windows produce valid MP4 output.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-007 - Thumbnail loading fallback

User story: As a user choosing a source, I want thumbnails where available and a graceful placeholder when they fail.

Expected behavior: Display/window thumbnails are captured sequentially. Cards show a progress indicator while loading and a dashed rectangle icon when no thumbnail is available. Thumbnail loading stops cleanly if the recording dialog task is cancelled while closing.

Manual steps:

1. Open recording dialog with multiple windows
2. observe thumbnail loading, fallback placeholder for any failed thumbnails, then close quickly during loading and verify no crash/stale update.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-008 - Countdown before recording

User story: As a user, I want a countdown before recording starts so I can prepare the screen.

Expected behavior: CountdownOverlay shows a non-activating HUD panel centered over the target frame counting 3, 2, 1, then starts recording only if not cancelled. The panel never becomes key and never activates Reel, so the window being demoed keeps focus; cancellation is by clicking the HUD or pressing the recording shortcut again. Both hotkey and recording-dialog start paths prevent overlapping countdowns.

Manual steps:

1. Focus a text field in another app
2. press the recording hotkey
3. verify the countdown HUD appears without Reel activating and the other app keeps keyboard focus
4. verify clicking the HUD cancels
5. verify pressing the hotkey again during the countdown cancels
6. verify repeated start attempts do not create overlapping countdowns.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-009 - Stop recording from menu

User story: As a recording user, I want the menu to clearly show recording state and stop capture.

Expected behavior: During recording, the status icon changes to filled red, the menu shows a disabled recording indicator and Stop Recording. Stop hides camera overlay, stops capture, finalizes the file, rebuilds the menu, and optionally opens preview. Unexpected stream stops abort cleanly by stopping device capture, cancelling the writer, discarding temp output, and clearing recording state.

Manual steps:

1. Start recording, stop from menu
2. verify red recording icon/menu state, output finalizes, preview/finder behavior follows settings
3. force stream interruption if possible and verify cleanup/no orphan temp file.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-010 - Quit while recording

User story: As a user who quits during recording, I want the in-progress recording finalized instead of lost.

Expected behavior: applicationShouldTerminate safely terminates immediately if the recorder is not initialized or not recording. If a recording is active, it delays termination, hides the camera overlay, awaits stopRecording, then replies to terminate.

Manual steps:

1. Start a recording and choose Quit Reel while recording
2. verify app delays quit, finalizes recording, hides camera overlay, and then terminates.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-011 - Output file creation

User story: As a user, I want recordings saved to a valid writable location with unique names.

Expected behavior: Recorder creates the configured output directory, verifies it is a writable directory, falls back to Movies if unavailable, and names files Reel-<timestamp>-<random>.mp4. Cancelled saves and unexpected stream errors discard temporary output instead of leaving orphan files.

Manual steps:

1. Set fixed output folder, record, verify unique Reel timestamp MP4
2. test unwritable/missing output folder fallback
3. verify cancelled saves and stream errors leave no orphan temp output.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-012 - Ask where to save

User story: As a user, I want to choose a save destination for each recording when Ask each time is enabled.

Expected behavior: After finalize, NSSavePanel opens with MP4 type and the generated filename. If user selects a URL, temp recording is moved or copied there. If user cancels, the temporary recording is discarded and no preview target is kept.

Manual steps:

1. Enable Ask each time
2. record
3. cancel save panel and verify no file/preview remains
4. repeat and save to chosen path
5. verify file exists and plays.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-013 - Open Finder after recording

User story: As a user, I want Finder to reveal the saved file when preview is disabled and reveal is enabled.

Expected behavior: After successful finalize, Finder selects the file only when openFinderAfterRecording is true and showPreviewAfterRecording is false. If Finder cannot reveal the saved file, Reel surfaces an error message in the menu instead of failing silently.

Manual steps:

1. Disable preview and enable Open Finder
2. record
3. verify Finder reveals saved file
4. simulate reveal failure if possible and verify menu error appears.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-014 - Preview after recording

User story: As a user, I want a preview window after capture so I can inspect, reveal, delete, or finish with the recording.

Expected behavior: If preview is enabled and lastRecordedURL exists, a resizable Recording Preview window opens with AVPlayerView, Reveal in Finder, Delete with confirmation, optional Save Trimmed, progress, errors, and Done. Closing the window clears AppDelegate preview state so later previews can open. Reveal in Finder shows a warning alert if Finder cannot reveal the recording.

Manual steps:

1. Enable preview
2. record
3. verify preview opens, plays, Done closes, title-bar close allows later previews, Reveal works or shows warning on failure.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-015 - Trim preview export

User story: As a user, I want to trim the start/end of a recording and export a new MP4.

Expected behavior: Trim handles maintain at least 0.5s range. Save Trimmed appears only after trim changes, prompts for MP4 path, exports to a hidden temporary MP4, and replaces the selected destination only after export succeeds; existing destination files are restored if replacement fails. After export, Reel reports an inline error if Finder cannot reveal the saved trimmed video.

Manual steps:

1. In preview, adjust trim start/end
2. export to new and existing paths
3. cancel save
4. verify rollback preserves existing file on failure and Finder reveal failure shows inline warning.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-016 - Delete recording from preview

User story: As a user, I want to delete an unwanted recording from the preview window after confirmation.

Expected behavior: Delete opens a destructive confirmation alert. Confirm removes the video file, closes preview on success, and shows an explicit warning alert with an OK button on failure.

Manual steps:

1. In preview, click Delete
2. cancel confirmation then verify file remains
3. confirm delete then verify file removed and preview closes
4. simulate remove failure and verify alert.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-017 - General settings

User story: As a user, I want general preferences to persist across launches.

Expected behavior: General settings include launch at login, ask/fixed save destination, output folder selection with writability validation, Finder reveal, preview after recording, and launch-at-login error display. Values persist in UserDefaults. Closing Settings clears AppDelegate state so Settings can be reopened.

Manual steps:

1. Open Settings
2. change each General setting
3. close/reopen and relaunch
4. verify persistence and stale window references do not prevent reopening.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-018 - Launch at login

User story: As a user, I want Reel to start at login when enabled and show an error if macOS rejects the change.

Expected behavior: Toggling launchAtLogin registers/unregisters SMAppService.mainApp. Failure sets a user-visible error and resyncs the toggle from the current SMAppService status instead of assuming a disabled state. Launch checks sync with current SMAppService status.

Manual steps:

1. From bundled app, toggle Launch at login on/off
2. verify SMAppService/login item state and UI state
3. simulate/observe failure and verify error plus resync to actual status.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-020 - Microphone audio recording

User story: As a user, I want optional microphone recording using my chosen input device.

Expected behavior: When enabled, Reel requests microphone permission, builds an AVCapture audio session from selected/default device, uses recommended writer settings when available, appends audio samples after video session starts, and warns if audio fails to start. If a saved audio device ID is no longer available, Settings shows an explicit Unavailable device row instead of a blank picker selection while recording falls back to default audio.

Manual steps:

1. Enable mic recording
2. test permission prompt/denial/grant
3. select device/default/stale device
4. record and verify audio track/sync and warning behavior on failure.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-021 - Camera overlay recording

User story: As a user, I want optional camera overlay with configurable camera, position, size, and shape.

Expected behavior: When enabled, Reel requests camera permission, starts a camera capture session, composites latest camera frames into the recording using selected shape and size, and shows a live draggable overlay excluded from screen capture. The overlay is hidden when recording stops, including unexpected not-recording transitions, stream-error abort stops camera capture resources, failed camera startup clears camera resources so no dead overlay is shown, and stale saved camera IDs are labeled as Unavailable device in Settings while recording falls back to default camera.

Manual steps:

1. Enable camera overlay
2. test camera permission denial/grant, shape/size/position, dragging, stale device label, failed camera start cleanup, stream-error overlay cleanup, and composited output.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-022 - Text overlay recording

User story: As a user, I want optional text overlay so I can watermark or label recordings.

Expected behavior: When enabled with non-empty trimmed text, Reel renders a centered white text overlay on a translucent dark rounded background at top, center, or bottom and composites it into frames. Long overlay text is capped to a reasonable fraction of capture height and placement is clamped so the overlay remains visible.

Manual steps:

1. Enable text overlay
2. test empty text, whitespace-only text, long text, top/center/bottom positions
3. record and visually verify overlay visibility and clamping.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-023 - Global hotkey toggle

User story: As a user, I want a global shortcut to start or stop recording.

Expected behavior: A Carbon-registered global shortcut toggles recording from anywhere without Accessibility permission. Starting this way skips the picker, so the status item menu and tooltip name the target the shortcut will capture — a display, a window, or an area with its pixel size — and say nothing when no target is selected and the shortcut would open the picker instead. The remembered selection is re-validated before each shortcut start, falling back to the picker when it no longer exists.

Manual steps:

1. Record a window, then open the status item menu and verify it names that window under Start Recording
2. hover the status item and verify the tooltip names the same target
3. switch to an area recording and verify both show the area and its size
4. clear the selection by closing the recorded window and verify the summary disappears and the shortcut opens the picker.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-024 - Hotkey customization

User story: As a user, I want to change the recording hotkey from Settings.

Expected behavior: Shortcuts tab button enters recording mode, local keyDown with Command, Control, or Option records keyCode and masked modifiers, Shift may be an additional modifier but cannot be the only modifier, Escape cancels, display string updates, UserDefaults persists usable combos, invalid stored combos fall back to default, and menu rebuilds on notification.

Manual steps:

1. Open Shortcuts
2. record valid shortcuts with Command/Control/Option, verify display/persistence
3. try Shift-only and verify rejection/beep
4. Escape cancels capture.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-025 - About window

User story: As a user, I want to see app version/build/commit and reach the project page.

Expected behavior: About window displays app icon, Reel title, tagline, version, build, commit or commit link when valid, and a GitHub button. Closing the window clears AppDelegate state so About can be reopened.

Manual steps:

1. Open About
2. verify icon/version/build/commit link/GitHub button
3. close via title bar and reopen
4. verify links open expected targets.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-026 - Sparkle update check

User story: As a user, I want to manually check for app updates from the menu.

Expected behavior: Menu item Check for Updates invokes SPUStandardUpdaterController.checkForUpdates. The menu label is centralized in AppMenuText. Info.plist points Sparkle at https://rselbach.github.io/reel/appcast.xml and includes a non-placeholder public EdDSA key.

Manual steps:

1. Choose Check for Updates
2. verify Sparkle UI opens and handles no-update/update/error states using configured appcast and public key.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-028 - Draggable camera overlay window

User story: As a recorder using the camera overlay, I want to drag the live camera preview during recording so I can keep it away from important screen content.

Expected behavior: When camera recording starts and a camera session is active, Reel creates a floating borderless overlay window sized as a fraction of the recording bounds, clips it to the selected shape, excludes the overlay window from screen capture, clamps drags inside the recorded bounds, and reports normalized x/y coordinates back to the recorder for compositing.

Manual steps:

1. Enable Record camera overlay, choose a camera, start a recording, drag the floating camera preview to each edge/corner, confirm it remains within the recorded bounds, confirm the final recording shows the camera overlay in the dragged position, and confirm the live floating window itself is not recursively captured.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-029 - Keyboard shortcut accessibility permission flow

User story: As a user without macOS Accessibility permission granted, I want Reel to show a clear way to enable keyboard shortcuts so the global hotkey can work.

Expected behavior: If Accessibility permission is missing, the menu shows Enable Keyboard Shortcuts. Selecting it prompts macOS for Accessibility permission, polls for up to 30 seconds, starts the hotkey manager once permission is available, and rebuilds the menu whether permission is granted or times out.

Manual steps:

1. Run Reel without Accessibility permission, open the menu, confirm Enable Keyboard Shortcuts appears, select it, grant permission in System Settings, confirm the menu item disappears after polling, and confirm the configured hotkey toggles recording.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-030 - Text overlay activation rules

User story: As a user configuring a text overlay, I want blank or whitespace-only overlay text to be ignored so recordings do not include an empty badge.

Expected behavior: The text overlay is active only when the setting is enabled and the configured text has non-whitespace content; active text is trimmed before being rendered into the recording.

Manual steps:

1. Enable Add text overlay with whitespace-only text and record briefly, confirm no empty overlay appears
2. then enter visible text with leading/trailing spaces, record again, and confirm only trimmed visible text appears.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-031 - About window repository and commit links

User story: As a user viewing About Reel, I want to see build provenance and open the project repository or exact commit when available.

Expected behavior: The About window displays app version, build number, and Git commit. Valid non-dev commit hashes are normalized and rendered as GitHub commit links; invalid or dev commits render as plain text. The GitHub button opens the Reel repository URL.

Manual steps:

1. Open About Reel, confirm version/build/commit display, click GitHub and confirm the project repository opens, and if the build has a valid commit hash click the commit link and confirm the exact GitHub commit opens.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-032 - Recording picker refresh and empty states

User story: As a user, I want to refresh the recording picker and understand why it is empty so I can recover without closing and reopening it.

Expected behavior: RecordingDialog always shows the refresh control, including when no windows are listed, and preselects the target the recorder is currently pointed at. Area recording offers both drawing a fresh area and reusing the remembered one, the latter labelled with its pixel size. With no windows but at least one display it explains that no open windows were found; with neither displays nor windows it explains the screen recording permission may not be in effect and offers a button that opens the System Settings privacy pane.

Manual steps:

1. Open the recording picker with screen recording permission revoked
2. verify the empty state explains the permission and the System Settings button opens the privacy pane
3. grant permission, press refresh, and verify displays and windows appear
4. record a window, reopen the picker, and verify that window is preselected
5. record an area, reopen the picker, and verify Use Last Area appears with the right dimensions and starts recording without redrawing.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-033 - Free space pre-flight check

User story: As a user, I want Reel to refuse to start a recording it cannot store so a full disk does not destroy the take.

Expected behavior: Before allocating any capture resources, startRecording reads the output volume's available capacity for important usage and compares it against two minutes of recording at the configured video quality bitrate. Below that floor the recording is refused with a message naming the free space, the approximate recordable duration, and the two ways out. When the volume cannot be queried the recording proceeds.

Manual steps:

1. Point the output folder at a nearly full volume
2. start a recording and verify it is refused with a message naming the free space and approximate duration
3. free up space and verify recording starts normally
4. set the output folder to a path that does not exist and verify recording still starts.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-034 - Low disk space auto-stop

User story: As a user recording a long demo, I want Reel to end the take while the file can still be saved rather than losing everything when the disk fills.

Expected behavior: While recording, a timer re-checks the destination volume every ten seconds. Once free space falls below thirty seconds of capture at the configured bitrate, the recording ends through the shared automatic-stop path: the stream is stopped, captured frames are finalized into a playable file, and the message explains the disk was almost full and how much space was left. Recordings that had captured no frames yet are discarded instead. The monitor is torn down on every recording teardown path.

Manual steps:

1. Start a recording on a volume with a few hundred megabytes free
2. fill the volume from another process while recording
3. verify the recording stops on its own within about ten seconds, the resulting file plays back, and the message names the remaining space.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-035 - Remembered recording target

User story: As a user, I want Reel to remember what I last recorded so the hotkey does not silently fall back to the primary display after a relaunch.

Expected behavior: A successful recording start persists its target: a display ID, an owning application bundle ID plus window title, or a display-local region rect. On the next launch, once shareable content has loaded, the target is restored. A remembered window is matched by app and title first and by app alone if the title changed, so a renamed window is still found; targets whose display, window, or region no longer exists leave the current selection untouched.

Manual steps:

1. Record a specific window
2. quit and relaunch Reel
3. press the hotkey and verify the same window is recorded rather than the primary display
4. repeat with an area selection
5. rename the recorded window's document and verify the same app's window is still selected
6. close the app entirely and verify the picker appears instead.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

## US-036 - Capture bounds indicator

User story: As a user recording a window or an area, I want to see exactly what is being captured so I do not discover the wrong bounds after the take.

Expected behavior: While recording an area or a window, a non-interactive red border is drawn around the captured bounds in a window excluded from capture, so it guides the user without appearing in the file. Window recordings keep the border in step with the window as it is moved or resized, through the same poll that moves the camera overlay. Full-display recordings show no border, since outlining the entire screen conveys nothing. The border is torn down whenever recording stops.

Manual steps:

1. Record a window with the camera overlay disabled
2. verify a red border outlines the window and follows it when the window is moved and resized
3. verify the border does not appear in the resulting file
4. record an area and verify the border appears around it
5. record a full display and verify no border is drawn
6. stop each recording and verify the border disappears.

Current status: Partial automated evidence passed; manual UI validation still pending. A bounded System Events probe on 2026-06-21 returned UI elements enabled = false, so this environment cannot inspect the app UI; validate manually using the listed steps.

Result: [ ] Pass  [ ] Fail  [ ] Blocked

Notes:

# No Further Manual Validation Required

## US-019 - Recording settings

User story: As a user, I want to configure cursor, frame rate, and video quality so recordings match my needs.

Automated evidence: swift test: testSettingsTextMatchesGeneralRecordingAndShortcutControls, testFrameRateSanitizationUsesSafeFallback, and testVideoQualityBitrates.

Current status: Not required beyond recorded automated evidence

## US-027 - Release/build tooling

User story: As a maintainer, I want reproducible app bundle, signing, notarization, and DMG recipes.

Automated evidence: swift test: testPackageManifestPinsMacOSPlatformAndSparkleDependency, testReleaseTagValidatorAcceptsSafeTagsAndRejectsUnsafeTags, and testGenerateAppcastWritesSanitizedVersionAndSignedEnclosure; just build-app, just dmg, and hdiutil verify passed in retests.

Current status: Not required beyond recorded automated evidence
