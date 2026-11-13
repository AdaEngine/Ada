#!/usr/bin/env bash
# Native bundles and Simulator launch evidence; no production QA entrypoints.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
check="${1:?Expected cpu-baker, saga-default, metal-native, ipad-simulator or studio-web}"
evidence="${2:?Expected an evidence directory}"
mkdir -p "$evidence"
exec > >(tee "$evidence/validation.log") 2>&1
xcodebuild -version
swift --version

# The Xcode wrappers run the build tool from the exact SwiftTerm revision in Editor/Package.swift.
if [[ "${GITHUB_ACTIONS:-}" == true && ( "$check" == ipad-simulator || "$check" == studio-web ) ]]; then
  python3 - <<'PY'
import json
from pathlib import Path

path = Path.home() / "Library/org.swift.swiftpm/security/plugins.json"
path.parent.mkdir(parents=True, exist_ok=True)
approvals = json.loads(path.read_text()) if path.exists() else []
approval = {
    "packageIdentity": "swiftterm",
    "targetName": "SwiftTermBuildInfoPlugin",
    "fingerprint": "caa1bdd3f1396c5b0ed66121f299d1c8b42bc94c",
}
if approval not in approvals:
    approvals.append(approval)
    path.write_text(json.dumps(approvals) + "\n")
PY
fi

case "$check" in
  cpu-baker)
    export ADAENGINE_HEADLESS=1 ADAENGINE_SKIP_WEBGPU_PLUGINS=1 ADAENGINE_WEB_EXPORT=1
    package="$(python3 script/shader_graph_validation_package.py "$RUNNER_TEMP/cpu-validation-package")"
    scratch="$RUNNER_TEMP/cpu-validation-build"
    swift build --package-path "$package" --scratch-path "$scratch" --jobs 3 --product ShaderGraphValidationBaker
    bin="$(swift build --package-path "$package" --scratch-path "$scratch" --show-bin-path)"
    ADAENGINE_SHADER_GRAPH_BAKER="$bin/ShaderGraphValidationBaker" \
      swift test --package-path "$package" --scratch-path "$scratch" --jobs 3 --no-parallel
    ;;
  saga-default)
    swift build --scratch-path "$RUNNER_TEMP/saga-default-build" --jobs 3 --target AdaEngine
    swift build --scratch-path "$RUNNER_TEMP/saga-tvos-build" --jobs 3 --target AdaEngine \
      --triple arm64-apple-tvos18.0 --sdk "$(xcrun --sdk appletvos --show-sdk-path)"
    ;;
  metal-native)
    export ADAENGINE_SAGA_METAL=0
    make -C Sources/gravity-lang -j 3 gravity
    package="$(python3 script/webgpu_validation_package.py "$RUNNER_TEMP/metal-validation-package")"
    # Preserve the failing gate's status while still exercising native export.
    metal_status=0
    ADAENGINE_GOLDEN_METAL=1 ADAENGINE_SPRITE_METAL_SMOKE=1 \
      ADAENGINE_GOLDEN_OUTPUT="$evidence/metal-frames" \
      swift test --package-path "$package" --scratch-path "$RUNNER_TEMP/metal-validation-build" \
      --jobs 3 --disable-sandbox --no-parallel \
      --filter 'ShaderGraph|SpriteGraphs|SpriteMetalRenderingTests|Render3D|GoldenFrameComparisonTests|GoldenBackendAgreementTests' \
      || metal_status=$?
    for kind in sprite pbr; do
      project="$RUNNER_TEMP/Graph $kind"
      python3 - "$root" "$project" "$kind" <<'PY'
from pathlib import Path
import json, shutil, sys
root, project = map(Path, sys.argv[1:3])
shutil.copytree(root / 'Editor/Tests/Fixtures/ShaderGraphSmoke', project)
if sys.argv[3] == 'pbr':
    if not (project / 'Assets/Scenes/PBR.ascn').is_file():
        raise RuntimeError('The PBR fixture is required for native acceptance')
    path = project / '.ada/project.json'
    data = json.loads(path.read_text())
    data['runtime']['plugins']['preset'] = 'game3d'
    data['runtime']['entry']['scene'] = 'Assets/Scenes/PBR.ascn'
    data['editor']['startupScene'] = 'Assets/Scenes/PBR.ascn'
    path.write_text(json.dumps(data))
    shutil.copy2(project / 'Examples/PBR.ada', project / 'Sources/PBR.ada')
PY
      ADAENGINE_SHADER_GRAPH_EXPORT_PROJECT="$project" \
        ADAENGINE_SHADER_GRAPH_EXPORT_OUTPUT="$RUNNER_TEMP/exports-$kind" \
        ADAENGINE_SHADER_GRAPH_EXPORT_BUILD_NATIVE=1 \
        ADAENGINE_SHADER_GRAPH_NATIVE_SCRATCH="$RUNNER_TEMP/native-child-$kind" \
        swift test --package-path Editor --scratch-path "$RUNNER_TEMP/editor-export-parent" \
        --jobs 3 --disable-sandbox --no-parallel --filter EditorShaderGraphExportTests
      bundle="$RUNNER_TEMP/exports-$kind/macOS/AdaNativeGame.app"
      test -x "$bundle/Contents/MacOS/AdaNativeGame"
      /usr/bin/open -n "$bundle"
      sleep 12
      /usr/bin/pgrep -x AdaNativeGame
      /usr/sbin/screencapture -x "$evidence/native-$kind.png"
      /usr/bin/pkill -x AdaNativeGame
    done
    exit "$metal_status"
    ;;
  ipad-simulator)
    if ! command -v xcodegen >/dev/null; then brew install xcodegen; fi
    xcrun simctl list devices available --json > "$evidence/simulators.json"
    device="$(python3 - "$evidence/simulators.json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))['devices']
matches = [d for runtime, group in devices.items() if 'iOS' in runtime
           for d in group if d.get('isAvailable') and 'iPad' in d['name']]
if not matches: raise RuntimeError('No available iPad Simulator')
print(matches[0]['udid'])
PY
)"
    if ! xcrun simctl list devices booted | grep -Fq "$device"; then xcrun simctl boot "$device"; fi
    xcrun simctl bootstatus "$device" -b
    xcodegen generate --spec Editor/project.yml
    xcodebuild -project Editor/AdaEditor.xcodeproj -scheme AdaEditor-iPadOS \
      -configuration Debug -destination "id=$device" -derivedDataPath "$RUNNER_TEMP/ipad-build" \
      CODE_SIGNING_ALLOWED=NO build
    bundle="$RUNNER_TEMP/ipad-build/Build/Products/Debug-iphonesimulator/Ada Studio.app"
    xcrun simctl install "$device" "$bundle"
    console="$evidence/ipad-console.log"
    SIMCTL_CHILD_ADAENGINE_SAGA_DEBUG=1 SIMCTL_CHILD_NSUnbufferedIO=YES \
      xcrun simctl launch --console --terminate-running-process "$device" org.adaengine.editor >"$console" 2>&1 &
    launch_pid=$!
    trap 'kill "$launch_pid" 2>/dev/null || true' EXIT
    for attempt in {1..90}; do
      if grep -Fq "[SAGA] pipeline 'Upscale Pipeline'" "$console"; then break; fi
      if ! kill -0 "$launch_pid" 2>/dev/null; then break; fi
      sleep 2
    done
    grep -F "[SAGA] pipeline 'Upscale Pipeline'" "$console"
    sleep 2
    xcrun simctl io "$device" screenshot "$evidence/ipad-studio.png"
    xcrun simctl spawn "$device" launchctl list | grep org.adaengine.editor
    xcrun simctl spawn "$device" log show --last 2m --style compact \
      --predicate 'process == "AdaEditor"' > "$evidence/ipad-runtime.log"
    xcrun simctl terminate "$device" org.adaengine.editor
    ;;
  studio-web)
    python3 ada_tool.py prepare wasm
    version="$(python3 -c 'import json; print(json.load(open("Tools/ada-toolchain.json"))["wasm"]["version"])')"
    sdk="$(python3 -c 'import json; print(json.load(open("Tools/ada-toolchain.json"))["wasm"]["sdk"])')"
    swift="$(swiftly run "+$version" swift -print-target-info | python3 -c \
      'import json, pathlib, sys; print(pathlib.Path(json.load(sys.stdin)["paths"]["runtimeResourcePath"]).parents[1] / "bin/swift")')"
    export PATH="${swift%/*}:$PATH"
    build="$RUNNER_TEMP/studio-web-build"
    python3 ada_tool.py build studio --debug --scratch-path "$build"
    cli="$build/Build/Products/Debug/Ada Studio.app/Contents/MacOS/adastudio"
    project="$RUNNER_TEMP/Shader Graph Smoke"
    ditto Editor/Tests/Fixtures/ShaderGraphSmoke "$project"
    output="$RUNNER_TEMP/studio-web-export"
    "$cli" export --target web --project "$project" --output "$output" \
      --scratch-path "$RUNNER_TEMP/studio-web-swiftpm" --swift "$swift" --swift-sdk "$sdk" --format json > "$evidence/export.json"
    playwright="$RUNNER_TEMP/studio-web-playwright"
    npm install --prefix "$playwright" --no-audit --no-fund playwright-core@1.58.2
    "$playwright/node_modules/.bin/playwright-core" install chromium
    SAGA_PLAYWRIGHT="$playwright/node_modules/playwright-core" \
      node script/web_golden_saga.mjs "$output/web" --studio-export --actual="$evidence/studio-web.png"
    ;;
  *) echo "Unknown Apple validation mode: $check" >&2; exit 2 ;;
esac
