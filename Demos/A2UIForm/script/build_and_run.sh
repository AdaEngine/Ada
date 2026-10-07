#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$DEMO_ROOT/../.." && pwd)"
BUILD_PATH="${ADAENGINE_A2UI_BUILD_PATH:-/private/tmp/adaengine-a2ui-build}"
mkdir -p "$BUILD_PATH"
BUILD_PATH="$(cd "$BUILD_PATH" && pwd -P)"
APP="$DEMO_ROOT/dist/A2UIFormDemo.app"
export ADAENGINE_DISABLE_SWAN=1
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/swift-cache"
case "$MODE" in run|--verify|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
for demo_pid in $(pgrep -f "$APP/Contents/MacOS/A2UIFormDemo" || true); do
    demo_command="$(ps -p "$demo_pid" -o command= || true)"
    if [[ "$demo_command" == "$APP/Contents/MacOS/A2UIFormDemo" || "$demo_command" == "$APP/Contents/MacOS/A2UIFormDemo "* ]]; then
        kill "$demo_pid"
    fi
done
mkdir -p "$DEMO_ROOT/dist"
if ! swift build --package-path "$REPO_ROOT" --scratch-path "$BUILD_PATH" --disable-sandbox --product A2UIFormDemo > "$DEMO_ROOT/dist/build.log" 2>&1; then
    tail -60 "$DEMO_ROOT/dist/build.log"
    exit 1
fi
BIN="$(swift build --package-path "$REPO_ROOT" --scratch-path "$BUILD_PATH" --disable-sandbox --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/A2UIFormDemo" "$APP/Contents/MacOS/"
for resource in "$BIN"/*.bundle; do
    [[ -d "$resource" ]] && cp -R "$resource" "$APP/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>A2UIFormDemo</string>
<key>CFBundleIdentifier</key><string>org.adaengine.demo.a2ui-form</string>
<key>CFBundleName</key><string>AdaUI A2UI Forms</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
: > "$DEMO_ROOT/dist/runtime.log"
if [[ "$MODE" == --debug ]]; then
    /usr/bin/lldb -- "$APP/Contents/MacOS/A2UIFormDemo"
    exit
fi
OPEN_ARGS=(-n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args)
if [[ "$MODE" == --verify ]]; then OPEN_ARGS+=(--verify --proof-directory "$DEMO_ROOT/dist/proof"); fi
/usr/bin/open "${OPEN_ARGS[@]}"
case "$MODE" in
    --verify)
        for attempt in {1..30}; do
            if rg -q 'A2UI demo verification PASS' "$DEMO_ROOT/dist/runtime.log"; then
                cat "$DEMO_ROOT/dist/runtime.log"
                exit 0
            fi
            if rg -q 'verification FAIL|Fatal error' "$DEMO_ROOT/dist/runtime.log"; then
                tail -40 "$DEMO_ROOT/dist/runtime.log"
                exit 1
            fi
            sleep 1
        done
        tail -40 "$DEMO_ROOT/dist/runtime.log"
        echo 'A2UI verification timed out' >&2
        exit 1
        ;;
    --logs|--telemetry) /usr/bin/log stream --info --style compact --predicate 'process == "A2UIFormDemo"' ;;
esac
