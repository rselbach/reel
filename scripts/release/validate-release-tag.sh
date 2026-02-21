#!/usr/bin/env bash

set -euo pipefail

readonly TAG="${1:-}"

if [[ -z "${TAG}" ]]; then
    echo "Usage: $0 <tag>"
    exit 1
fi

readonly SAFE_TAG="$(printf '%s' "$TAG" | tr -cd 'A-Za-z0-9._-')"
if [[ -z "$SAFE_TAG" || "$SAFE_TAG" != "$TAG" ]]; then
    echo "Invalid release tag: $TAG"
    exit 1
fi

echo "$SAFE_TAG"
