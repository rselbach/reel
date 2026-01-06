# Reel build recipes
# Usage: just <recipe> [args]

set shell := ["bash", "-cu"]

app_name := "Reel"
bundle_id := "com.rselbach.reel"
app_dir := ".build/" + app_name + ".app"
entitlements := "Reel.entitlements"

# Default recipe: build the app
default: build-app

# Build swift package in release mode
build:
    swift build -c release

# Build the .app bundle
build-app: build
    #!/usr/bin/env bash
    set -e
    rm -rf "{{ app_dir }}"
    mkdir -p "{{ app_dir }}/Contents/MacOS"
    mkdir -p "{{ app_dir }}/Contents/Resources"
    mkdir -p "{{ app_dir }}/Contents/Frameworks"
    cp .build/release/Reel "{{ app_dir }}/Contents/MacOS/"
    cp Sources/Info.plist "{{ app_dir }}/Contents/Info.plist"
    # Inject git commit hash
    GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
    /usr/libexec/PlistBuddy -c "Set :GitCommit $GIT_COMMIT" "{{ app_dir }}/Contents/Info.plist"
    echo "Embedded commit: $GIT_COMMIT"
    cp Sources/AppIcon.icns "{{ app_dir }}/Contents/Resources/"
    cp -R .build/arm64-apple-macosx/release/Sparkle.framework "{{ app_dir }}/Contents/Frameworks/"
    install_name_tool -add_rpath @executable_path/../Frameworks "{{ app_dir }}/Contents/MacOS/Reel"
    echo "Built: {{ app_dir }}"
    echo "Run: open '{{ app_dir }}'"

# Code sign the app (requires SIGNING_IDENTITY env var)
sign: build-app
    #!/usr/bin/env bash
    set -e
    if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
        echo "Error: SIGNING_IDENTITY not set"
        echo "Find your identity with: security find-identity -v -p codesigning"
        echo "Then: export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'"
        exit 1
    fi
    echo "Signing with: $SIGNING_IDENTITY"
    codesign --force --options runtime --deep \
        --sign "$SIGNING_IDENTITY" \
        "{{ app_dir }}/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime --entitlements "{{ entitlements }}" \
        --sign "$SIGNING_IDENTITY" \
        "{{ app_dir }}/Contents/MacOS/Reel"
    codesign --force --options runtime --entitlements "{{ entitlements }}" \
        --sign "$SIGNING_IDENTITY" \
        "{{ app_dir }}"
    echo "Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "{{ app_dir }}"
    echo "Signature valid!"

# Sign and notarize the app (requires SIGNING_IDENTITY and NOTARIZE_PROFILE env vars)
notarize: sign
    #!/usr/bin/env bash
    set -e
    zip_path=".build/{{ app_name }}.zip"
    profile="${NOTARIZE_PROFILE:-NOTARIZE_PROFILE}"
    echo "Creating zip for notarization..."
    ditto -c -k --keepParent "{{ app_dir }}" "$zip_path"
    echo "Submitting for notarization..."
    xcrun notarytool submit "$zip_path" \
        --keychain-profile "$profile" \
        --wait
    echo "Stapling notarization ticket..."
    xcrun stapler staple "{{ app_dir }}"
    rm "$zip_path"
    echo "Notarization complete!"

# Create a .dmg installer from existing app bundle (no rebuild)
_dmg-only:
    #!/usr/bin/env bash
    set -e
    dmg_path=".build/{{ app_name }}.dmg"
    dmg_staging=".build/dmg"
    echo "Creating DMG..."
    rm -rf "$dmg_staging" "$dmg_path"
    mkdir -p "$dmg_staging"
    cp -R "{{ app_dir }}" "$dmg_staging/"
    ln -s /Applications "$dmg_staging/Applications"
    hdiutil create -volname "{{ app_name }}" -srcfolder "$dmg_staging" -ov -format UDZO "$dmg_path"
    rm -rf "$dmg_staging"
    echo "Created: $dmg_path"

# Create a .dmg installer (unsigned)
dmg: build-app _dmg-only

# Sign an existing DMG (requires SIGNING_IDENTITY env var)
_sign-dmg:
    #!/usr/bin/env bash
    set -e
    dmg_path=".build/{{ app_name }}.dmg"
    if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
        echo "Error: SIGNING_IDENTITY not set"
        exit 1
    fi
    echo "Signing DMG..."
    codesign --force --sign "$SIGNING_IDENTITY" "$dmg_path"
    echo "Signed: $dmg_path"

# Create a signed .dmg installer (requires SIGNING_IDENTITY env var)
dmg-signed: sign _dmg-only _sign-dmg

# Open the built app
run: build-app
    open "{{ app_dir }}"

# Clean build artifacts
clean:
    rm -rf .build

# List available signing identities
list-identities:
    security find-identity -v -p codesigning

# Show help
help:
    @echo "Reel build system"
    @echo ""
    @echo "Recipes:"
    @echo "  build          Build swift package (release)"
    @echo "  build-app      Build the .app bundle (default)"
    @echo "  sign           Code sign the app"
    @echo "  notarize       Sign and notarize the app"
    @echo "  dmg            Create unsigned .dmg"
    @echo "  dmg-signed     Create signed .dmg"
    @echo "  run            Build and open the app"
    @echo "  clean          Remove build artifacts"
    @echo "  list-identities Show available signing certs"
    @echo ""
    @echo "Environment variables:"
    @echo "  SIGNING_IDENTITY   Developer ID Application certificate"
    @echo "  NOTARIZE_PROFILE   Keychain profile for notarytool"
