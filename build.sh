#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}
BUILD="$ROOT/build"
APP="$BUILD/HeatWatch.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc \
  -O -wmo \
  -target arm64-apple-macos13.0 \
  -import-objc-header "$ROOT/Sources/Bridging.h" \
  -framework AppKit -framework ServiceManagement -framework IOKit -framework CoreFoundation \
  -o "$APP/Contents/MacOS/HeatWatch" \
  "$ROOT"/Sources/*.swift "$ROOT"/Sources/*.c

codesign --force --sign - --identifier local.renato.heatwatch "$APP"

echo "built: $APP"
echo "size: $(du -sh "$APP" | cut -f1)"
