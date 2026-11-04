#!/bin/zsh
# Runs an interface test script (see Sources/DiskInventoryM/UIDriver.swift) in a real app window.
# Usage: scripts/ui-test.sh <script> [<log>]
set -euo pipefail

cd "$(dirname "$0")/.."
script="$(realpath "$1")"
log="${2:-$PWD/build/ui-test.log}"
app="$PWD/build/ui-test/Disk Inventory M.app"

swift build -c release --product DiskInventoryM --scratch-path .build/ui-test -Xswiftc -DUITEST
binary="$(swift build -c release --product DiskInventoryM --scratch-path .build/ui-test -Xswiftc -DUITEST --show-bin-path)/DiskInventoryM"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/DiskInventoryM"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/CleanupRules.json "$app/Contents/Resources/CleanupRules.json"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$app"

rm -f "$log"
open -W -n --env "DIM_UI_SCRIPT=$script" --env "DIM_UI_LOG=$log" "$app"
cat "$log"
grep -q "finished, 0 failed" "$log"
