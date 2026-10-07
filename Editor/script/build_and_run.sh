#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ "${ADA_EDITOR_STANDALONE_SWIFTPM:-0}" == "1" ]]; then
    editor_package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    editor_engine_root="$(dirname "$editor_package_root")"
    editor_swift="${ADA_EDITOR_SWIFT:-swift}"
    editor_scratch="${ADA_EDITOR_SCRATCH:-$editor_engine_root/.build-studio-dev}"
    editor_app_name="${ADA_EDITOR_APP_NAME:-Ada Studio Dev}"
    editor_app="$editor_package_root/dist/$editor_app_name.app"
    editor_binary="$editor_app/Contents/MacOS/$editor_app_name"
    for editor_pid in $(pgrep -f "$editor_binary" || true); do
        editor_command="$(ps -p "$editor_pid" -o command= || true)"
        if [[ "$editor_command" == "$editor_binary" || "$editor_command" == "$editor_binary "* ]]; then kill "$editor_pid"; fi
    done
    export ADAENGINE_ANDROID=0 ADAENGINE_DISABLE_SWAN=1 ADAENGINE_HEADLESS=1
    mkdir -p "$editor_scratch/package-roots"
    editor_canonical_engine="${ADAENGINE_PACKAGE_PATH:-$editor_scratch/package-roots/AdaEngine}"
    if [[ ! -e "$editor_canonical_engine" ]]; then ln -s "$editor_engine_root" "$editor_canonical_engine"; fi
    if [[ "$(cd "$editor_canonical_engine" && pwd -P)" != "$editor_engine_root" ]]; then
        echo "The task build directory belongs to another engine checkout." >&2
        exit 1
    fi
    export ADAENGINE_PACKAGE_PATH="$editor_canonical_engine"
    export CLANG_MODULE_CACHE_PATH="$editor_scratch/clang-cache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$editor_scratch/swift-cache"
    "$editor_swift" build --package-path "$editor_package_root" --scratch-path "$editor_scratch" --product AdaEditor --jobs 6 --disable-sandbox --skip-update
    editor_bin_directory="$("$editor_swift" build --package-path "$editor_package_root" --scratch-path "$editor_scratch" --show-bin-path)"
    mkdir -p "$editor_app/Contents/MacOS" "$editor_app/Contents/Resources"
    editor_signed_binary="$editor_scratch/AdaEditor-signed-dev"
    cp "$editor_bin_directory/AdaEditor" "$editor_signed_binary"
    codesign --force --sign - "$editor_signed_binary"
    /usr/bin/ditto "$editor_signed_binary" "$editor_binary"
    rm -rf "$editor_app/Contents/_CodeSignature"
    for editor_resource in "$editor_bin_directory"/*.bundle "$editor_bin_directory"/*.resources; do
        [[ -e "$editor_resource" ]] || continue
        /usr/bin/ditto "$editor_resource" "$editor_app/$(basename "$editor_resource")"
    done
    /usr/bin/python3 "$editor_package_root/scripts/stage-build-sdk.py" --engine-root "$editor_engine_root" --compiler-root "${ADAENGINE_GRAVITY_PACKAGE_PATH:-$editor_scratch/checkouts/gravity-lang}" --output "$editor_app/Contents/Resources/BuildSDK"
    /usr/bin/python3 - "$editor_app/Contents/Info.plist" "$editor_app_name" <<'PY_PLIST'
import plistlib,sys
with open(sys.argv[1],"wb") as stream:
    plistlib.dump({"CFBundleExecutable":sys.argv[2],"CFBundleIdentifier":"org.adaengine.studio.dev","CFBundleName":sys.argv[2],
                  "CFBundlePackageType":"APPL","NSPrincipalClass":"NSApplication","LSMinimumSystemVersion":"15.0",
                  "AdaEditorDistribution":"standalone"},stream)
PY_PLIST
    # SwiftPM's executable already has its linker-generated development signature.
    # This source-development bundle is not a notarized distribution artifact.
    case "$MODE" in
        run|--verify|verify)
            if [[ -n "${ADA_EDITOR_LOG_PATH:-}" ]]; then
                editor_launch_args=(-n "$editor_app")
                if [[ -n "${ADA_EDITOR_QA_SHELL:-}" ]]; then editor_launch_args+=(--env "SHELL=$ADA_EDITOR_QA_SHELL"); fi
                /usr/bin/open "${editor_launch_args[@]}" --stdout "$ADA_EDITOR_LOG_PATH" --stderr "$ADA_EDITOR_LOG_PATH" --args "${@:2}"
            else
                /usr/bin/open -n "$editor_app" --args "${@:2}"
            fi
            ;;
        --debug|debug) lldb -- "$editor_binary" "${@:2}" ;;
        --logs|logs) /usr/bin/open -n "$editor_app" --args "${@:2}"; /usr/bin/log stream --info --predicate "process == \"$editor_app_name\"" ;;
        *) echo "usage: $0 [run|--verify|--debug|--logs] [Studio arguments]" >&2; exit 2 ;;
    esac
    exit 0
fi
PRODUCT_NAME="Ada Studio"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/AdaEditor.xcodeproj"
DERIVED_DATA="${ADA_EDITOR_DERIVED_DATA:-$ROOT_DIR/.build/xcode}"
BUILD_PRODUCTS="$DERIVED_DATA/Build/Products/Debug"
APP_BUNDLE="$ROOT_DIR/dist/$PRODUCT_NAME.app"
BUILT_APP="$BUILD_PRODUCTS/$PRODUCT_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

# Stop only instances belonging to this checkout, preserving other Studio sessions.
for pid in $(pgrep -f "$APP_BINARY" || true); do
    running_command="$(ps -p "$pid" -o command= || true)"
    if [[ "$running_command" == "$APP_BINARY" || "$running_command" == "$APP_BINARY "* ]]; then kill "$pid"; fi
done

xcodegen generate --spec "$ROOT_DIR/project.yml"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "AdaEditor-macOS" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$BUILT_APP" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.adaengine.editor"'
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$PRODUCT_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
