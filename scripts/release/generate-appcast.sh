#!/usr/bin/env bash

set -euo pipefail

VERSION="${1:-}"
SPARKLE_SIGNATURE="${2:-}"
OUTPUT_FILE="${3:-_site/appcast.xml}"

if [[ -z "$VERSION" || -z "$SPARKLE_SIGNATURE" ]]; then
    echo "Usage: $0 <version> <sparkle-signature> [output-file]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFE_VERSION="$("$SCRIPT_DIR/validate-release-tag.sh" "$VERSION")"

mkdir -p "$(dirname "$OUTPUT_FILE")"
DATE=$(date -R)

cat > "$OUTPUT_FILE" <<XML
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
      <enclosure url="https://github.com/rselbach/reel/releases/download/v${VERSION}/Reel.dmg" ${SPARKLE_SIGNATURE} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
