#!/usr/bin/env bash

set -euo pipefail

readonly VERSION="${1:-}"
readonly INFO_PLIST="${2:-Sources/Info.plist}"

if [[ -z "${VERSION}" ]]; then
    echo "Usage: $0 <version> [info-plist]"
    exit 1
fi

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Info.plist not found: $INFO_PLIST"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFE_VERSION="$("$SCRIPT_DIR/validate-release-tag.sh" "$VERSION")"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SAFE_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SAFE_VERSION" "$INFO_PLIST"
