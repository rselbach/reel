#!/usr/bin/env bash

set -euo pipefail

APP_PATH="${1:-}"
ZIP_PATH="${2:-}"
PROFILE="${NOTARIZE_PROFILE:-NOTARIZE_PROFILE}"

if [[ -z "$APP_PATH" || -z "$ZIP_PATH" ]]; then
    echo "Usage: $0 <app-path> <zip-path>"
    exit 1
fi

SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$PROFILE" \
    --wait \
    --output-format json)

echo "$SUBMIT_OUTPUT"

parse_notary_json_value() {
    local key="$1"
    local value

    if ! value=$(printf '%s' "$SUBMIT_OUTPUT" | /usr/bin/python3 -c \
        "import json,sys; data=json.load(sys.stdin); print(data.get('$key', ''))" 2>/dev/null); then
        echo "Failed to parse notarytool JSON output."
        echo "$SUBMIT_OUTPUT"
        exit 1
    fi

    printf '%s' "$value"
}

SUBMISSION_ID="$(parse_notary_json_value id)"
SUBMISSION_STATUS="$(parse_notary_json_value status)"

if [[ -z "$SUBMISSION_ID" || -z "$SUBMISSION_STATUS" ]]; then
    echo "Missing notarization metadata in output."
    echo "$SUBMIT_OUTPUT"
    exit 1
fi

if [[ "$SUBMISSION_STATUS" != "Accepted" ]]; then
    echo "Notarization failed (status=$SUBMISSION_STATUS, id=$SUBMISSION_ID)."
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE"
    exit 1
fi

xcrun stapler staple "$APP_PATH"
