#!/usr/bin/env bash
set -euo pipefail
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$DEMO_ROOT/../.." && pwd)"
BUILD_PATH="${ADAENGINE_SKELETAL_BUILD_PATH:-/tmp/adaengine-skeletal-import-build}"
MODE="${1:-run}"
CONFIGURATION="${ADAENGINE_SKELETAL_CONFIGURATION:-release}"
if [[ "$MODE" == --debug ]]; then CONFIGURATION=debug; fi
LAUNCH_ENV=()
if [[ -n "${TINT_EXECUTABLE:-}" ]]; then LAUNCH_ENV+=(--env "TINT_EXECUTABLE=$TINT_EXECUTABLE"); fi
export CLANG_MODULE_CACHE_PATH="$BUILD_PATH/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_PATH/swift-cache"
APP="$DEMO_ROOT/dist/SkeletalGarden.app"
mkdir -p "$DEMO_ROOT/dist"
if [[ "${ADAENGINE_SKIP_BUILD:-0}" != 1 ]] && ! swift build --package-path "$REPO_ROOT" --disable-sandbox --scratch-path "$BUILD_PATH" --product SkeletalGarden --configuration "$CONFIGURATION" > "$DEMO_ROOT/dist/build.log" 2>&1; then
    tail -80 "$DEMO_ROOT/dist/build.log"
    exit 1
fi
BIN="${ADAENGINE_SKELETAL_BIN_PATH:-$(swift build --package-path "$REPO_ROOT" --disable-sandbox --scratch-path "$BUILD_PATH" --configuration "$CONFIGURATION" --show-bin-path)}"
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
    --capture-tree-lods)
        mkdir -p "$DEMO_ROOT/dist/captures/tree-lods"
        /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --metal --render-proof --daylight --tree-lod-proof --capture-directory "$DEMO_ROOT/dist/captures/tree-lods"
        ;;
    --capture-crowd-lod|--capture-crowd|--capture-crowd-reference|--capture-gpu-visibility|--capture-cpu-visibility|--capture-quality|--capture-baseline|--capture-no-ao|--capture-no-aa|--capture-single-shadows|--capture-no-shadows|--capture-visibility|--capture-no-culling|--capture-no-lod|--capture-unoptimized|--capture-temporal|--capture-temporal-motion|--capture-spatial|--capture-spatial-motion|--capture-temporal-multi|--capture-local-lights|--capture-local-no-lights|--capture-local-unshadowed|--capture-local-point|--capture-local-spot|--capture-local-budget|--capture-local-many|--capture-local-moving|--capture-local-multi)
        NAME="${MODE#--capture-}"
        mkdir -p "$DEMO_ROOT/dist/captures/$NAME"
        rm -f "$DEMO_ROOT/dist/captures/$NAME/frame-30.png" "$DEMO_ROOT/dist/captures/$NAME/frame-50.png" "$DEMO_ROOT/dist/captures/$NAME/gpu-timings.json"
        EXTRA=(--measure-gpu)
        case "$NAME" in
            crowd-lod) EXTRA+=(--metal --crowd --profile-frames) ;;
            crowd) EXTRA+=(--metal --crowd --gpu-visibility --profile-frames) ;;
            crowd-reference) EXTRA+=(--metal --crowd --no-character-lod --profile-frames) ;;
            gpu-visibility) EXTRA+=(--metal --gpu-visibility) ;;
            cpu-visibility) EXTRA+=(--metal) ;;
            temporal) EXTRA+=(--temporal) ;;
            local-lights) EXTRA+=(--local-lights) ;;
            local-no-lights) EXTRA+=(--local-lights --no-local-lights) ;;
            local-unshadowed) EXTRA+=(--local-lights --no-local-shadows) ;;
            local-point) EXTRA+=(--local-lights --point-only) ;;
            local-spot) EXTRA+=(--local-lights --spot-only) ;;
            local-budget) EXTRA+=(--local-lights --local-shadow-budget) ;;
            local-many) EXTRA+=(--local-lights --many-local-lights) ;;
            local-multi) EXTRA+=(--local-lights --temporal-multi) ;;
            local-moving) EXTRA+=(--local-lights --local-motion --temporal-motion) ;;
            temporal-multi) EXTRA+=(--temporal --temporal-multi) ;;
            temporal-motion) EXTRA+=(--temporal --temporal-motion) ;;
            spatial) EXTRA+=(--spatial-proof --no-aa) ;;
            spatial-motion) EXTRA+=(--spatial-proof --no-aa --temporal-motion) ;;
            baseline) EXTRA+=(--render-baseline) ;;
            no-ao) EXTRA+=(--no-ao) ;;
            no-aa) EXTRA+=(--no-aa) ;;
            single-shadows) EXTRA+=(--single-shadows) ;;
            no-shadows) EXTRA+=(--no-shadows) ;;
            no-culling) EXTRA+=(--no-culling) ;;
            no-lod) EXTRA+=(--no-lod) ;;
            unoptimized) EXTRA+=(--no-culling --no-lod --no-distance-culling) ;;
        esac
        /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --render-proof "${EXTRA[@]}" --capture-directory "$DEMO_ROOT/dist/captures/$NAME"
        ;;
    --capture-overview)
        mkdir -p "$DEMO_ROOT/dist/captures/overview"
        rm -f "$DEMO_ROOT/dist/captures/overview/frame-30.png" "$DEMO_ROOT/dist/captures/overview/frame-50.png"
        /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --pose-proof --overview-proof --capture-directory "$DEMO_ROOT/dist/captures/overview"
        ;;
    --capture-no-ibl)
        mkdir -p "$DEMO_ROOT/dist/captures/no-ibl"
        rm -f "$DEMO_ROOT/dist/captures/no-ibl/frame-30.png" "$DEMO_ROOT/dist/captures/no-ibl/frame-50.png"
        /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --pose-proof --no-ibl --capture-directory "$DEMO_ROOT/dist/captures/no-ibl"
        ;;
    --capture)
        mkdir -p "$DEMO_ROOT/dist/captures"
        rm -f "$DEMO_ROOT/dist/captures/frame-30.png" "$DEMO_ROOT/dist/captures/frame-50.png"
        /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --pose-proof --capture-directory "$DEMO_ROOT/dist/captures"
        ;;
    --daylight|--webgpu|--metal|--gpu-visibility) /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args "$MODE" ;;
    --profile-frames) /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --metal --profile-frames ;;
    --local-lights) /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --local-lights ;;
    --temporal) /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --temporal ;;
    run) /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" ;;
    --autoplay) /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --autoplay ;;
    --verify|--verify-temporal|--verify-local-lights)
        EXTRA=()
        if [[ "$MODE" == --verify-temporal ]]; then EXTRA+=(--temporal); fi
        if [[ "$MODE" == --verify-local-lights ]]; then EXTRA+=(--local-lights --temporal); fi
        /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log" --args --controller-proof ${EXTRA[@]+"${EXTRA[@]}"}
        for attempt in {1..30}; do
            if rg -q 'controller verification PASS' "$DEMO_ROOT/dist/runtime.log"; then
                cat "$DEMO_ROOT/dist/runtime.log"
                exit 0
            fi
            if { (( attempt > 3 )) && ! /usr/bin/pgrep -x SkeletalGarden >/dev/null; } || rg -q 'controller .* FAIL|startup failed' "$DEMO_ROOT/dist/runtime.log"; then
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
        /usr/bin/open -n "$APP" ${LAUNCH_ENV[@]+"${LAUNCH_ENV[@]}"} --stdout "$DEMO_ROOT/dist/runtime.log" --stderr "$DEMO_ROOT/dist/runtime.log"
        /usr/bin/log stream --info --style compact --predicate 'process == "SkeletalGarden"'
        ;;
    *) echo 'usage: build_and_run.sh [run|--daylight|--webgpu|--temporal|--local-lights|--autoplay|--capture|--capture-overview|--capture-tree-lods|--capture-no-ibl|--capture-quality|--capture-baseline|--capture-no-ao|--capture-no-aa|--capture-single-shadows|--capture-no-shadows|--capture-visibility|--capture-no-culling|--capture-no-lod|--capture-unoptimized|--capture-temporal|--capture-temporal-motion|--capture-spatial|--capture-spatial-motion|--verify|--capture-temporal-multi|--verify-temporal|--verify-local-lights|--capture-local-{lights,no-lights,unshadowed,point,spot,budget,many,moving,multi}|--debug|--logs]' >&2; exit 2 ;;
esac
