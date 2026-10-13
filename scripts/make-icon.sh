#!/bin/sh
# Regenerates Resources/AppIcon.icns and docs/logo.png from scripts/make-icon.swift.
set -eu
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
swift scripts/make-icon.swift "$TMP/icon.png"
mkdir -p "$TMP/AppIcon.iconset"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
sips -Z 256 "$TMP/icon.png" --out docs/logo.png >/dev/null
echo "Updated Resources/AppIcon.icns and docs/logo.png"
