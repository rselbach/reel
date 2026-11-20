#!/usr/bin/env bash
# Generates and validates Sparkle appcast.xml for a tagged release.

set -euo pipefail

readonly VERSION="${1:-}"
readonly SPARKLE_SIGNATURE="${2:-}"
readonly OUTPUT_FILE="${3:-_site/appcast.xml}"

if [[ -z "${VERSION}" || -z "${SPARKLE_SIGNATURE}" ]]; then
  echo "Usage: $0 <version> <sparkle-signature> [output-file]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFE_VERSION="$("${SCRIPT_DIR}/validate-release-tag.sh" "${VERSION}")"

SIGNATURE_REGEX='^(sparkle:edSignature="[A-Za-z0-9+/=]+"[[:space:]]+length="[0-9]+"|length="[0-9]+"[[:space:]]+sparkle:edSignature="[A-Za-z0-9+/=]+")$'
if [[ ! "${SPARKLE_SIGNATURE}" =~ ${SIGNATURE_REGEX} ]]; then
  echo "Invalid Sparkle signature format." >&2
  exit 1
fi

INFO_PLIST="${SCRIPT_DIR}/../../Sources/Info.plist"
if [[ ! -f "${INFO_PLIST}" ]]; then
  echo "Info.plist not found: ${INFO_PLIST}" >&2
  exit 1
fi

MIN_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${INFO_PLIST}")"
if [[ ! "${MIN_SYSTEM_VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "Invalid LSMinimumSystemVersion in ${INFO_PLIST}: ${MIN_SYSTEM_VERSION}" >&2
  exit 1
fi

# sign_update emits attribute-ready output (e.g.
# 'sparkle:edSignature="..." length="..."'), so it can be interpolated into
# the enclosure tag verbatim after regex validation above.

OUTPUT_DIR="$(dirname "${OUTPUT_FILE}")"
mkdir -p "${OUTPUT_DIR}"
if [[ -e "${OUTPUT_FILE}" && ! -f "${OUTPUT_FILE}" ]]; then
  echo "Output path is not writable: ${OUTPUT_FILE}" >&2
  exit 1
fi

DATE="$(date -R)"
TMP_FILE="$(mktemp "${OUTPUT_DIR}/.appcast.XXXXXX")"
trap 'rm -f "${TMP_FILE}"' EXIT

cat > "${TMP_FILE}" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Reel Updates</title>
    <link>https://rselbach.github.io/reel/appcast.xml</link>
    <description>Reel app updates</description>
    <language>en</language>
    <item>
      <title>Version ${SAFE_VERSION}</title>
      <pubDate>${DATE}</pubDate>
      <sparkle:version>${SAFE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SAFE_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/rselbach/reel/releases/download/v${SAFE_VERSION}/Reel.dmg" ${SPARKLE_SIGNATURE} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

if ! /usr/bin/python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "${TMP_FILE}" >&2; then
  echo "Generated appcast XML failed validation." >&2
  exit 1
fi

mv "${TMP_FILE}" "${OUTPUT_FILE}"
