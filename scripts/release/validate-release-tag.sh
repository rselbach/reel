#!/usr/bin/env bash
# Validates release tag text before it is used in package metadata and URLs.

set -euo pipefail

readonly TAG="${1:-}"

if [[ -z "${TAG}" ]]; then
  echo "Usage: $0 <tag>" >&2
  exit 1
fi

SAFE_TAG=""
if ! SAFE_TAG="$(printf '%s' "${TAG}" | tr -cd 'A-Za-z0-9._-')"; then
  echo "Failed to validate release tag." >&2
  exit 1
fi
readonly SAFE_TAG
if [[ -z "${SAFE_TAG}" || "${SAFE_TAG}" != "${TAG}" ]]; then
  echo "Invalid release tag: ${TAG}" >&2
  exit 1
fi

echo "${SAFE_TAG}"
