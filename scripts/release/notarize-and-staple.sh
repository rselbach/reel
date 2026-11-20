#!/usr/bin/env bash
# Submits an archive or DMG to Apple notarization and staples the ticket.

set -euo pipefail

parse_notary_json_value() {
  local key="$1"
  local value

  if ! value=$(printf '%s' "${SUBMIT_OUTPUT}" | /usr/bin/python3 -c \
    'import json, sys; data = json.load(sys.stdin); print(data.get(sys.argv[1], ""))' \
    "${key}" 2>/dev/null); then
    echo "Failed to parse notarytool JSON output." >&2
    echo "${SUBMIT_OUTPUT}" >&2
    exit 1
  fi

  printf '%s' "${value}"
}

main() {
  local target_path="${1:-}"
  local submission_path="${2:-}"
  local profile="${NOTARIZE_PROFILE:-NOTARIZE_PROFILE}"
  local keychain="${NOTARIZE_KEYCHAIN:-${KEYCHAIN_PATH:-}}"
  local submit_status=0
  local submission_id
  local submission_status
  local -a notary_args

  if [[ -z "${target_path}" || -z "${submission_path}" ]]; then
    echo "Usage: $0 <target-path> <submission-path>" >&2
    exit 1
  fi

  if [[ ! -e "${target_path}" ]]; then
    echo "Target path not found: ${target_path}" >&2
    exit 1
  fi

  if [[ ! -f "${submission_path}" ]]; then
    echo "Submission path not found: ${submission_path}" >&2
    exit 1
  fi

  notary_args=(--keychain-profile "${profile}")
  if [[ -n "${keychain}" ]]; then
    notary_args+=(--keychain "${keychain}")
  fi

  SUBMIT_OUTPUT="$(xcrun notarytool submit "${submission_path}" \
    "${notary_args[@]}" \
    --wait \
    --output-format json 2>&1)" || submit_status=$?

  if (( submit_status != 0 )); then
    echo "${SUBMIT_OUTPUT}" >&2
    echo "Notarization submission failed (exit=${submit_status})." >&2
    exit "${submit_status}"
  fi

  echo "${SUBMIT_OUTPUT}"

  submission_id="$(parse_notary_json_value id)"
  submission_status="$(parse_notary_json_value status)"

  if [[ -z "${submission_id}" || -z "${submission_status}" ]]; then
    echo "Missing notarization metadata in output." >&2
    echo "${SUBMIT_OUTPUT}" >&2
    exit 1
  fi

  if [[ "${submission_status}" != "Accepted" ]]; then
    echo "Notarization failed (status=${submission_status}, id=${submission_id})." >&2
    xcrun notarytool log "${submission_id}" "${notary_args[@]}" >&2 || true
    exit 1
  fi

  xcrun stapler staple "${target_path}"
}

main "$@"
