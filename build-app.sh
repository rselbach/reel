#!/bin/bash
set -e

APP_NAME="Reel"
BUNDLE_ID="com.rselbach.reel"
APP_DIR=".build/${APP_NAME}.app"
ENTITLEMENTS="Reel.entitlements"

# Code signing identity - set this to your Developer ID Application certificate
# Find yours with: security find-identity -v -p codesigning
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

# Notarization profile name (stored via: xcrun notarytool store-credentials)
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-NOTARIZE_PROFILE}"

usage() {
    echo "Usage: $0 [--sign] [--notarize] [--help]"
    echo ""
    echo "Options:"
    echo "  --sign       Code sign the app (requires SIGNING_IDENTITY env var)"
    echo "  --notarize   Sign and notarize (requires --sign, NOTARIZE_PROFILE env var)"
    echo "  --help       Show this help"
    echo ""
    echo "Environment variables:"
    echo "  SIGNING_IDENTITY   Developer ID Application certificate name or hash"
    echo "  NOTARIZE_PROFILE   Keychain profile name for notarytool credentials"
    exit 0
}

DO_SIGN=false
DO_NOTARIZE=false

for arg in "$@"; do
    case $arg in
        --sign)
            DO_SIGN=true
            ;;
        --notarize)
            DO_SIGN=true
            DO_NOTARIZE=true
            ;;
        --help)
            usage
            ;;
    esac
done

echo "Building $APP_NAME..."
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp .build/release/Reel "$APP_DIR/Contents/MacOS/"
cp Sources/Info.plist "$APP_DIR/Contents/Info.plist"

echo "Built: $APP_DIR"

if [ "$DO_SIGN" = true ]; then
    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "Error: SIGNING_IDENTITY not set"
        echo "Find your identity with: security find-identity -v -p codesigning"
        echo "Then: export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'"
        exit 1
    fi

    echo "Signing with: $SIGNING_IDENTITY"
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR/Contents/MacOS/Reel"
    
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_DIR"
    
    echo "Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    echo "Signature valid!"
fi

if [ "$DO_NOTARIZE" = true ]; then
    ZIP_PATH=".build/${APP_NAME}.zip"
    
    echo "Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
    
    echo "Submitting for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_DIR"
    
    rm "$ZIP_PATH"
    echo "Notarization complete!"
fi

echo ""
echo "Run: open '$APP_DIR'"
