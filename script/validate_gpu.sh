#!/bin/bash
# Run the GPU validation suites on SAGA native (Vulkan on Windows and Linux; Metal on macOS is validated separately).
set -euo pipefail
ada_validation_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ada_validation_root"
if [[ "${OS:-}" == "Windows_NT" ]]; then
  ada_validation_python="${ADAENGINE_PYTHON:-python}"
else
  ada_validation_python="${ADAENGINE_PYTHON:-python3}"
fi
export ADAENGINE_VALIDATE_WGSL=1 ADAENGINE_SPRITE_SAGA_SMOKE=1 ADAENGINE_GOLDEN_SAGA=1 ADAENGINE_SAGA_WINDOWLESS=1
export ADAENGINE_SHADER_SOURCE_ROOT="$ada_validation_root"
ada_validation_scratch="${ADAENGINE_GPU_SCRATCH:-/tmp/adaengine-gpu-dev-validation}"
ada_validation_configuration="${ADAENGINE_SWIFT_CONFIGURATION:-debug}"
ada_validation_compiler_args=()
if [[ "$ada_validation_configuration" == "release" ]]; then
  ada_validation_compiler_args=(-Xswiftc -enable-testing)
fi
ada_validation_job_args=()
if [[ -n "${ADAENGINE_SWIFT_JOBS:-}" ]]; then
  ada_validation_job_args=(--jobs "$ADAENGINE_SWIFT_JOBS")
fi
ada_validation_package_args=()
ada_validation_product_args=(--product RenderingValidationPackageTests)
if [[ "${ADAENGINE_VALIDATE_SPONZA:-}" == "1" ]]; then
  ada_validation_package_args=(--include-sponza-demo)
  ada_validation_product_args=(--build-tests)
fi
ada_validation_package="$("$ada_validation_python" script/gpu_validation_package.py "$ada_validation_scratch/validation-package" "${ada_validation_package_args[@]}")"
# The GPU suites share one process-wide renderer, so the validation package runs its tests one at a time.
ada_validation_filter='PluginLoadingTests|WESLShaderModuleTests|WESLGradientPipelineTests|WESLUIPipelineTests|WGSLReflectionTests|ShaderGraph|SpriteGraphs|SpriteMetalRenderingTests/rendersLayoutsAndPickingWithSAGA|SpriteMetalRenderingTests/rendersTileOcclusionWithSAGA|BoundedResourceCacheTests|RenderGraphDiagnosticsTests|WindowFrameRequestsTests|MaterialUploadReuseTests|OptionalResourceTests|ShaderIncluderTests|ShaderCacheKeyTests|RenderUpscalingTests|Render3D|GoldenFrameComparisonTests|GoldenBackendAgreementTests|VisibleMesh3DListsEquivalenceTests'
ada_validation_filter="$ada_validation_filter|Particle3DTests"
ada_validation_filter="$ada_validation_filter|ColorCurves3DTests"
ada_validation_filter="${ADAENGINE_GPU_TEST_FILTER:-$ada_validation_filter}"
if [[ "${OS:-}" == "Windows_NT" ]]; then
  export ADAENGINE_SHADER_SOURCE_ROOT="$(cygpath -m "$ada_validation_root")"
  # Building the test product avoids compiling unrelated dependency command
  # plugins (JavaScriptKit's PackageToJS currently cannot compile on Windows).
  swift build -c "$ada_validation_configuration" "${ada_validation_compiler_args[@]}" "${ada_validation_job_args[@]}" --package-path "$ada_validation_package" "${ada_validation_product_args[@]}" \
    --disable-sandbox --scratch-path "$ada_validation_scratch"
  swift test -c "$ada_validation_configuration" --package-path "$ada_validation_package" --skip-build --scratch-path "$ada_validation_scratch" \
    --no-parallel --filter "$ada_validation_filter"
else
  swift test -c "$ada_validation_configuration" "${ada_validation_compiler_args[@]}" "${ada_validation_job_args[@]}" --package-path "$ada_validation_package" --disable-sandbox --scratch-path "$ada_validation_scratch" \
    --no-parallel --filter "$ada_validation_filter"
fi
