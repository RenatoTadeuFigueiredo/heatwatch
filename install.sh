#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h}

"$ROOT/build.sh"

pkill -x HeatWatch 2>/dev/null || true
sleep 1

rm -rf /Applications/HeatWatch.app
cp -R "$ROOT/build/HeatWatch.app" /Applications/

open /Applications/HeatWatch.app
echo "installed: /Applications/HeatWatch.app"
