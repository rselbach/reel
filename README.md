# Reel

A lightweight macOS screen recording app built with Swift and ScreenCaptureKit.

## Features

**Capture**

- Record a full display, an individual window, or a selected area
- Area selection is adjustable before recording, with a live size readout and
  an optional 16:9 lock
- Pause and resume mid-take; the pause is removed from the finished file
- Discard a ruined take without saving it
- The recording target is remembered across launches, and the menu says what
  the shortcut will capture

**Output**

- H.264 or HEVC, at native resolution or capped to 1440p, 1080p, or 720p
- Configurable frame rate and video quality
- Window recordings can be framed on a background with rounded corners and a
  shadow, in solid or gradient presets
- Click highlighting, so viewers can see clicks and drags
- Optional camera overlay (circle or rectangle, positioned and sized during the
  countdown, before the take starts)
- Optional text overlay for watermark-style labels

**Audio**

- Microphone or system audio capture
- Live input meter, so a muted microphone is obvious before recording

**After the take**

- Preview with lossless trimming, a smaller 720p copy, or a looping GIF
- Drag or copy the file straight out of the preview
- Record Again to go straight into the next take

**Elsewhere**

- Global shortcuts for start/stop, pause, and discard
- Refuses to start, and stops cleanly, rather than losing a take to a full disk
- Menu bar app with minimal UI
- Automatic updates via Sparkle

## Requirements

- macOS 26.0 or later (Swift 6.2)

## Building

```bash
swift build
```

Or use the included build script for a full app bundle:

```bash
just build-app
```

## Auto-Updates Setup (for maintainers)

Releases are signed with Sparkle for automatic updates. To set up:

1. Generate an EdDSA keypair (after running `swift build` once):
   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

2. Add the private key to GitHub Secrets as `SPARKLE_PRIVATE_KEY`

3. Replace `SPARKLE_PUBLIC_KEY_PLACEHOLDER` in `Sources/Info.plist` with the public key

The CI workflow will sign each release and update `appcast.xml` automatically.

## Disclaimer

This is a personal project made for my own use. It is **not supported** in any way — no issues, no PRs, no guarantees it works, no promises it won't set your Mac on fire. Use at your own risk. If it breaks, you get to keep both pieces.

## License

Public Domain (Unlicense) — do whatever you want with it. See [LICENSE](LICENSE).
