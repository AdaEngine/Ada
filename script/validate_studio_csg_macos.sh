#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
test "$(uname -s)" = Darwin

scratch="${1:?Pass the SwiftPM Editor scratch path used to build AdaEditor}"
evidence="${RUNNER_TEMP:-$repo/.build-tools/contribution}/csg-macos"
mkdir -p "$evidence"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/studio-csg.XXXXXX")"
player_pid=
cleanup() {
    if [[ -n "$player_pid" ]]; then
        kill "$player_pid" 2>/dev/null || true
        wait "$player_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

bin="$(swift build --package-path Editor --scratch-path "$scratch" --show-bin-path)"
gravity="$repo/Sources/gravity-lang"
if [[ ! -x "$gravity/gravity" ]]; then
    make -C "$gravity" -j4
fi
ditto Editor/Tests/Fixtures/CSGTwoRooms "$work/project"
ADAENGINE_PACKAGE_PATH="$repo" ADAENGINE_GRAVITY_PACKAGE_PATH="$gravity" \
    "$bin/AdaEditor" --ada-studio-cli export --target macos --project "$work/project" \
    --configuration debug --output "$work/export" --scratch-path "$work/player-build" \
    --format json > "$evidence/export.json"

bundle="$work/export/AdaNativeGame.app"
find "$bundle" -type f -name '*.glb' -print -quit | grep -q .
cat > "$work/window.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let pid = Int(CommandLine.arguments[1])
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: {
    ($0[kCGWindowOwnerPID as String] as? Int) == pid &&
    ($0[kCGWindowLayer as String] as? Int) == 0
}), let number = window[kCGWindowNumber as String] as? Int {
    print(number)
}
SWIFT
swiftc "$work/window.swift" -o "$work/window"
"$bundle/Contents/MacOS/AdaNativeGame" > "$evidence/player.log" 2>&1 &
player_pid=$!
for ((attempt = 0; attempt < 60; attempt++)); do
    if ! kill -0 "$player_pid" 2>/dev/null || grep -Fq 'Startup failed' "$evidence/player.log"; then
        cat "$evidence/player.log" >&2
        exit 1
    fi
    if grep -Fq 'Native game ready' "$evidence/player.log"; then
        window="$("$work/window" "$player_pid")"
        if [[ -n "$window" ]]; then
            sleep 2
            /usr/sbin/screencapture -x -l "$window" "$evidence/csg-window.png"
            test -s "$evidence/csg-window.png"
            exit 0
        fi
    fi
    sleep 1
done

cat "$evidence/player.log" >&2
echo "The packaged CSG player did not show a game window." >&2
exit 1
