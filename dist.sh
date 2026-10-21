#!/bin/zsh
set -euo pipefail

# Packages a distributable build. Without a Developer ID the archive is merely
# ad-hoc signed and recipients must clear the quarantine flag by hand.
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE="heatwatch" ./dist.sh
#
# NOTARY_PROFILE is created once with:
#   xcrun notarytool store-credentials heatwatch --apple-id ... --team-id ... --password ...

ROOT=${0:A:h}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")
DIST="$ROOT/dist"
mkdir -p "$DIST"
APP="$ROOT/build/HeatWatch.app"
STAGE="$DIST/HeatWatch-$VERSION"

"$ROOT/build.sh"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --deep "$APP"

  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "submitting to the notary service…"
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$DIST/notarize.zip"
  else
    echo "warning: signed but not notarized — Gatekeeper will still warn on other Macs"
  fi
else
  echo "warning: ad-hoc build — recipients must clear the quarantine flag (see INSTALL.txt)"
fi

rm -rf "$DIST"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "$ROOT/Resources/INSTALL.txt" "$STAGE/"
cp "$ROOT/LICENSE" "$STAGE/"

ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$DIST/HeatWatch-$VERSION.zip"
hdiutil create -quiet -volname "HeatWatch $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DIST/HeatWatch-$VERSION.dmg"

cd "$DIST"
shasum -a 256 "HeatWatch-$VERSION.zip" "HeatWatch-$VERSION.dmg" > SHA256SUMS

echo
echo "artifacts in $DIST"
ls -lh "$DIST"
