# Reel

A lightweight macOS screen recording app built with Swift and ScreenCaptureKit.

## Features

- Record full screen or individual windows
- Optional camera overlay (circle or rectangle, configurable position and size)
- Optional text overlay for watermark-style labels
- Microphone audio capture
- Configurable frame rate and video quality
- Global hotkey support
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
