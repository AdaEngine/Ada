#!/bin/bash
# Always exercise Tint; do not silently accept cached WGSL or skip a missing tool.
set -euo pipefail
ada_validation_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ada_validation_root"
if [[ "${OS:-}" == "Windows_NT" ]]; then
  ada_validation_python="${ADAENGINE_PYTHON:-python}"
else
  ada_validation_python="${ADAENGINE_PYTHON:-python3}"
fi
export TINT_EXECUTABLE
TINT_EXECUTABLE="$("$ada_validation_python" script/ensure_tint.py)"
export ADAENGINE_WEB_EXPORT=1 ADAENGINE_VALIDATE_TINT=1 ADAENGINE_SPRITE_WGPU_SMOKE=1 ADAENGINE_GOLDEN_WEBGPU=1
export ADAENGINE_WEBGPU_VISIBILITY_SMOKE=1 ADAENGINE_WEBGPU_SCENE_SMOKE=1
export ADAENGINE_SHADER_SOURCE_ROOT="$ada_validation_root"
ada_validation_scratch="${ADAENGINE_WEBGPU_SCRATCH:-/tmp/adaengine-webgpu-dev-validation}"
ada_validation_job_args=()
if [[ -n "${ADAENGINE_SWIFT_JOBS:-}" ]]; then
  ada_validation_job_args=(--jobs "$ADAENGINE_SWIFT_JOBS")
fi
ada_validation_package="$("$ada_validation_python" script/webgpu_validation_package.py "$ada_validation_scratch/validation-package")"
# The GPU suites share one process-wide renderer, so the validation package runs its tests one at a time.
ada_validation_filter='PluginLoadingTests|TintToolchainTests|TintShaderCompilerTests|WGSLReflectionTests|ShaderGraph|SpriteGraphs|SpriteMetalRenderingTests/rendersLayoutsAndPickingWithWebGPU|SpriteMetalRenderingTests/rendersTileOcclusionWithWebGPU|BoundedResourceCacheTests|RenderGraphDiagnosticsTests|WindowFrameRequestsTests|WGPUBindingStateTests|WGPUVisibilityProcessorTests|MaterialUploadReuseTests|OptionalResourceTests|ShaderIncluderTests|ShaderCacheKeyTests|RenderUpscalingTests|Render3D|GoldenFrameComparisonTests|GoldenBackendAgreementTests|VisibleMesh3DListsEquivalenceTests'
ada_validation_filter="$ada_validation_filter|Particle3DTests"
ada_validation_filter="${ADAENGINE_WEBGPU_TEST_FILTER:-$ada_validation_filter}"
if [[ "${OS:-}" == "Windows_NT" ]]; then
  export ADAENGINE_SHADER_SOURCE_ROOT="$(cygpath -m "$ada_validation_root")"
  # Building the test product avoids compiling unrelated dependency command
  # plugins (JavaScriptKit's PackageToJS currently cannot compile on Windows).
  swift build "${ada_validation_job_args[@]}" --package-path "$ada_validation_package" --product RenderingValidationPackageTests \
    --disable-sandbox --scratch-path "$ada_validation_scratch"
  swift test --package-path "$ada_validation_package" --skip-build --scratch-path "$ada_validation_scratch" \
    --no-parallel --filter "$ada_validation_filter"
else
  swift test "${ada_validation_job_args[@]}" --package-path "$ada_validation_package" --disable-sandbox --scratch-path "$ada_validation_scratch" \
    --no-parallel --filter "$ada_validation_filter"
fi
