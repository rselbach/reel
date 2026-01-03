# Reel

A lightweight macOS screen recording app built with Swift and ScreenCaptureKit.

## Features

- Record full screen or individual windows
- Optional camera overlay (circle or rectangle, configurable position and size)
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
./build-app.sh
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

## Why?

I made this because I wanted a simple screen recorder that does exactly what I need without the bloat in order to record quick demos/tutorials for teammates at work. It's a personal project to scratch my own itch, but you're welcome to use it.

## License

MIT License - see [LICENSE](LICENSE) for details.
