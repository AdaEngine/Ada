#!/usr/bin/env bash
set -euo pipefail
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$DEMO_ROOT/../.." && pwd)"
BUILD_PATH="${ADAENGINE_SKELETAL_BUILD_PATH:-/tmp/adaengine-skeletal-import-build}"
MODE="${1:-run}"
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/swift-cache"
APP="$DEMO_ROOT/dist/SkeletalGarden.app"
mkdir -p "$DEMO_ROOT/dist"
if ! swift build --package-path "$REPO_ROOT" --disable-sandbox --scratch-path "$BUILD_PATH" --product SkeletalGarden > "$DEMO_ROOT/dist/build.log" 2>&1; then
    tail -80 "$DEMO_ROOT/dist/build.log"
    exit 1
fi
BIN="$(swift build --package-path "$REPO_ROOT" --disable-sandbox --scratch-path "$BUILD_PATH" --show-bin-path)"
/usr/bin/pkill -x SkeletalGarden >/dev/null 2>&1 || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SkeletalGarden" "$APP/Contents/MacOS/SkeletalGarden"
for resource in "$BIN"/*.bundle; do
    [[ -d "$resource" ]] || continue
    cp -R "$resource" "$APP/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SkeletalGarden</string>
<key>CFBundleIdentifier</key><string>org.adaengine.demo.skeletal-garden</string>
<key>CFBundleName</key><string>Skeletal Garden</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
: > "$DEMO_ROOT/dist/runtime.log"
case "$MODE" in
    --capture)
        mkdir -p "$DEMO_ROOT/dist/captures"
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --pose-proof --capture-directory "$DEMO_ROOT/dist/captures"
        ;;
    run) /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" ;;
    --autoplay) /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --autoplay ;;
    --verify)
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --autoplay
        sleep 8
        if ! /usr/bin/pgrep -x SkeletalGarden >/dev/null; then
            tail -60 "$DEMO_ROOT/dist/runtime.log"
            exit 1
        fi
        ;;
    --debug) /usr/bin/lldb -- "$APP/Contents/MacOS/SkeletalGarden" ;;
    --logs)
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log"
        /usr/bin/log stream --info --style compact --predicate 'process == "SkeletalGarden"'
        ;;
    *) echo 'usage: build_and_run.sh [run|--autoplay|--capture|--verify|--debug|--logs]' >&2; exit 2 ;;
esac
