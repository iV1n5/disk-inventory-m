#!/bin/zsh
# Tests the interface end to end, in the real app, on a throwaway disk image. Nothing outside the
# image is touched: even the Trash used is the image's own.
# Usage: Tests/UI/run.sh [<folder for pictures>]
set -uo pipefail

cd "$(dirname "$0")/../.."
out="${1:-$PWD/build/ui-test-output}"
mkdir -p "$out"
work="$(mktemp -d)"
volume="$work/mnt"
result=0

cleanup() {
    hdiutil detach -quiet -force "$volume" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

hdiutil create -quiet -size 40m -fs APFS -volname DIMTest "$work/test.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$volume" "$work/test.dmg"

fill() { mkdir -p "$(dirname "$volume/$1")"; dd if=/dev/urandom of="$volume/$1" bs=1k count="$2" 2>/dev/null; }
fill Projects/alpha/big.dat 9216
fill Projects/alpha/code.swift 701
fill Projects/beta/notes.txt 2048
fill Media/movie.mov 7168
fill Media/photo.jpg 3072
fill Throwaway/delete-me.log 4096
fill Sample.app/Contents/MacOS/Sample 2048

# Runs one script. Its log is removed first, so that a run that never got going can't pass for one
# that did by leaving the previous run's results in place.
run_script() {
    local name="$1" log="$out/$1-log.txt" script="$work/$1.ui"
    rm -f "$log"
    sed -e "s#{{VOLUME}}#$volume#g" -e "s#{{OUT}}#$out#g" -e "s#{{PROJECT}}#$PWD#g" "Tests/UI/$name.ui" > "$script"
    scripts/ui-test.sh "$script" "$log" > "$out/$name-output.txt" 2>&1 || result=1
    if [[ -f "$log" ]]; then
        echo "$name: $(grep -c '  ok:' "$log") passed"
        grep -E "FAILED|^finished" "$log"
    else
        echo "FAILED: $name did not run"
        grep -E "error:" "$out/$name-output.txt" | head -5
    fi
}

rm -f "$out/trash-result.txt"
run_script volume
[[ "$(cat "$out/trash-result.txt" 2>/dev/null)" == "gone" ]] || { echo "FAILED: the trashed file is still there"; result=1; }
run_script launch
run_script quicklook
exit $result
