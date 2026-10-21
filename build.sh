#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}
BUILD="$ROOT/build"
APP="$BUILD/HeatWatch.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for locale in en pt-BR; do
  ditto "$ROOT/Resources/$locale.lproj" "$APP/Contents/Resources/$locale.lproj"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Universal binary: Apple Silicon and Intel. Intel Macs have no `PMU tdie`
# sensors, so they run on the CPU-load fallback.
for arch in arm64 x86_64; do
  swiftc \
    -O -wmo \
    -target "$arch-apple-macos13.0" \
    -import-objc-header "$ROOT/Sources/Bridging.h" \
    -framework AppKit -framework ServiceManagement -framework IOKit -framework CoreFoundation \
    -o "$BUILD/HeatWatch-$arch" \
    "$ROOT"/Sources/*.swift "$ROOT"/Sources/*.c
done

lipo -create -output "$APP/Contents/MacOS/HeatWatch" \
  "$BUILD/HeatWatch-arm64" "$BUILD/HeatWatch-x86_64"
rm -f "$BUILD/HeatWatch-arm64" "$BUILD/HeatWatch-x86_64"

# Ad-hoc signature with hardened runtime, so the same build can be notarized
# later without changing the pipeline.
codesign --force --options runtime --sign - --identifier io.github.renatotadeufigueiredo.heatwatch "$APP"

echo "built: $APP"
echo "size: $(du -sh "$APP" | cut -f1)"
lipo -info "$APP/Contents/MacOS/HeatWatch"
