#!/bin/zsh
# Builds "build/Disk Inventory M.app". Needs only the Command Line Tools, not Xcode.
#
# Signs ad hoc by default. To keep a Full Disk Access grant across rebuilds, sign with a stable
# identity instead:  SIGN_IDENTITY="My Certificate" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
app="build/Disk Inventory M.app"

swift build -c release --product DiskInventoryM
binary="$(swift build -c release --product DiskInventoryM --show-bin-path)/DiskInventoryM"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/DiskInventoryM"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/CleanupRules.json "$app/Contents/Resources/CleanupRules.json"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# The linker records where the object files were, which would put the path of this folder, and so
# the name of whoever built it, into an app that gets passed around.
strip -S "$app/Contents/MacOS/DiskInventoryM"

codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$app"
echo "Built $app"
