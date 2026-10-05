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
    --capture-quality|--capture-baseline|--capture-no-ao|--capture-no-aa|--capture-single-shadows|--capture-no-shadows|--capture-visibility|--capture-no-culling|--capture-no-lod|--capture-unoptimized)
        NAME="${MODE#--capture-}"
        mkdir -p "$DEMO_ROOT/dist/captures/$NAME"
        rm -f "$DEMO_ROOT/dist/captures/$NAME/frame-30.png" "$DEMO_ROOT/dist/captures/$NAME/frame-50.png" "$DEMO_ROOT/dist/captures/$NAME/gpu-timings.json"
        EXTRA=(--measure-gpu)
        case "$NAME" in
            baseline) EXTRA+=(--render-baseline) ;;
            no-ao) EXTRA+=(--no-ao) ;;
            no-aa) EXTRA+=(--no-aa) ;;
            single-shadows) EXTRA+=(--single-shadows) ;;
            no-shadows) EXTRA+=(--no-shadows) ;;
            no-culling) EXTRA+=(--no-culling) ;;
            no-lod) EXTRA+=(--no-lod) ;;
            unoptimized) EXTRA+=(--no-culling --no-lod --no-distance-culling) ;;
        esac
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --render-proof "${EXTRA[@]}" --capture-directory "$DEMO_ROOT/dist/captures/$NAME"
        ;;
    --capture-overview)
        mkdir -p "$DEMO_ROOT/dist/captures/overview"
        rm -f "$DEMO_ROOT/dist/captures/overview/frame-30.png" "$DEMO_ROOT/dist/captures/overview/frame-50.png"
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --pose-proof --overview-proof --capture-directory "$DEMO_ROOT/dist/captures/overview"
        ;;
    --capture-no-ibl)
        mkdir -p "$DEMO_ROOT/dist/captures/no-ibl"
        rm -f "$DEMO_ROOT/dist/captures/no-ibl/frame-30.png" "$DEMO_ROOT/dist/captures/no-ibl/frame-50.png"
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --pose-proof --no-ibl --capture-directory "$DEMO_ROOT/dist/captures/no-ibl"
        ;;
    --capture)
        mkdir -p "$DEMO_ROOT/dist/captures"
        rm -f "$DEMO_ROOT/dist/captures/frame-30.png" "$DEMO_ROOT/dist/captures/frame-50.png"
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --pose-proof --capture-directory "$DEMO_ROOT/dist/captures"
        ;;
    run) /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" ;;
    --autoplay) /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --autoplay ;;
    --verify)
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --controller-proof
        for attempt in {1..30}; do
            if rg -q 'controller verification PASS' "$DEMO_ROOT/dist/runtime.log"; then
                cat "$DEMO_ROOT/dist/runtime.log"
                exit 0
            fi
            if ! /usr/bin/pgrep -x SkeletalGarden >/dev/null || rg -q 'controller .* FAIL|startup failed' "$DEMO_ROOT/dist/runtime.log"; then
                tail -60 "$DEMO_ROOT/dist/runtime.log"
                exit 1
            fi
            sleep 1
        done
        tail -60 "$DEMO_ROOT/dist/runtime.log"
        echo 'Controller verification timed out' >&2
        exit 1
        ;;
    --debug) /usr/bin/lldb -- "$APP/Contents/MacOS/SkeletalGarden" ;;
    --logs)
        /usr/bin/open -n "$APP" --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log"
        /usr/bin/log stream --info --style compact --predicate 'process == "SkeletalGarden"'
        ;;
    *) echo 'usage: build_and_run.sh [run|--autoplay|--capture|--capture-overview|--capture-no-ibl|--capture-quality|--capture-baseline|--capture-no-ao|--capture-no-aa|--capture-single-shadows|--capture-no-shadows|--capture-visibility|--capture-no-culling|--capture-no-lod|--capture-unoptimized|--verify|--debug|--logs]' >&2; exit 2 ;;
esac
