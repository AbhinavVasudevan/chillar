#!/bin/sh
# Builds Chillar.app into ./build.
#   ./build.sh           build
#   ./build.sh install   build, copy to /Applications and (re)start it
#   ./build.sh dev       build with developer-only snapshot tooling (never ship this)
set -e
cd "$(dirname "$0")"
MODE="${1:-}"
IDENTITY="${CHILLAR_SIGN_IDENTITY:-Chillar Local Signing}"
APP=build/Chillar.app
BIN=.build/release/Chillar
mkdir -p .build/release

FLAGS="-O -parse-as-library -target $(uname -m)-apple-macosx14.0"
[ "$MODE" = dev ] && FLAGS="$FLAGS -D CHILLAR_DEV"
. scripts/sdkflag.sh
swiftc $FLAGS $SDKFLAG Sources/Chillar/*.swift -o "$BIN"

rm -rf "$APP"
VERSION=$(cat VERSION)
BUNDLE_ID=io.github.chillar
# Dev builds get their own identity, so they can never share the release app's Keychain items,
# preferences or login item.
[ "$MODE" = dev ] && BUNDLE_ID=io.github.chillar.dev
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Chillar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Chillar</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Chillar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with any broker.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# A stable signing identity keeps Keychain access across rebuilds (see scripts/create-signing-cert.sh).
if [ "$MODE" = dev ]; then
  SIGN=-   # dev builds never read credentials (see Store.init), so ad-hoc is fine
elif security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  SIGN=-
  echo "warning: signing identity \"$IDENTITY\" not found; using ad-hoc signing."
  echo "         Keychain access will reset on every rebuild. Run scripts/create-signing-cert.sh once to fix."
fi
if [ "$MODE" = dev ]; then
  # Dev builds read fixtures and write snapshots anywhere, so they skip the sandbox. Never ship one.
  codesign --force --options runtime --sign "$SIGN" "$APP"
else
  codesign --force --options runtime --entitlements Chillar.entitlements --sign "$SIGN" "$APP"
fi
echo "Built $APP"

if [ "$MODE" = install ]; then
  DEST=/Applications/Chillar.app
  # Only replace an existing app if it really is Chillar.
  if [ -e "$DEST" ]; then
    EXISTING=$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
    if [ "$EXISTING" != "io.github.chillar" ]; then
      echo "error: $DEST exists but isn't Chillar (bundle id: ${EXISTING:-unknown}). Not touching it." >&2
      exit 1
    fi
  fi
  pkill -f "^$DEST/Contents/MacOS/Chillar" || true
  rm -rf "$DEST" && cp -R "$APP" /Applications/
  open /Applications/Chillar.app
  echo "Installed to /Applications/Chillar.app"
fi
