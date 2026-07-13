#!/usr/bin/env bash
# Validates release tag text before it is used in package metadata and URLs.

set -euo pipefail

readonly TAG="${1:-}"

if [[ -z "${TAG}" ]]; then
  echo "Usage: $0 <tag>" >&2
  exit 1
fi

if [[ ! "${TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid release version: ${TAG}. Expected X.Y.Z." >&2
  exit 1
fi

echo "${TAG}"
