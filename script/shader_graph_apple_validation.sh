#!/usr/bin/env bash
# Native bundles and Simulator launch evidence; no production QA entrypoints.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
check="${1:?Expected cpu-baker, metal-native or ipad-simulator}"
evidence="${2:?Expected an evidence directory}"
mkdir -p "$evidence"
exec > >(tee "$evidence/validation.log") 2>&1
xcodebuild -version
swift --version

case "$check" in
  cpu-baker)
    export ADAENGINE_HEADLESS=1 ADAENGINE_SKIP_WEBGPU_PLUGINS=1 ADAENGINE_WEB_EXPORT=1
    package="$(python3 script/shader_graph_validation_package.py "$RUNNER_TEMP/cpu-validation-package")"
    scratch="$RUNNER_TEMP/cpu-validation-build"
    swift build --package-path "$package" --scratch-path "$scratch" --jobs 3 --product AdaShaderGraphBaker
    bin="$(swift build --package-path "$package" --scratch-path "$scratch" --show-bin-path)"
    ADAENGINE_SHADER_GRAPH_BAKER="$bin/AdaShaderGraphBaker" \
      swift test --package-path "$package" --scratch-path "$scratch" --jobs 3 --no-parallel
    ;;
  metal-native)
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
    xcrun simctl launch --terminate-running-process "$device" org.adaengine.editor
    sleep 12
    xcrun simctl io "$device" screenshot "$evidence/ipad-studio.png"
    xcrun simctl spawn "$device" launchctl list | grep org.adaengine.editor
    xcrun simctl spawn "$device" log show --last 2m --style compact \
      --predicate 'process == "AdaEditor"' > "$evidence/ipad-runtime.log"
    xcrun simctl terminate "$device" org.adaengine.editor
    ;;
  *) echo "Unknown Apple validation mode: $check" >&2; exit 2 ;;
esac
