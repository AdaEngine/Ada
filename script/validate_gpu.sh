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
ada_validation_build_args=(-c "$ada_validation_configuration")
if [[ "$ada_validation_configuration" == "release" ]]; then
  ada_validation_build_args+=(-Xswiftc -enable-testing)
fi
if [[ -n "${ADAENGINE_SWIFT_JOBS:-}" ]]; then
  ada_validation_build_args+=(--jobs "$ADAENGINE_SWIFT_JOBS")
fi
ada_validation_package_args=("$ada_validation_scratch/validation-package")
ada_validation_product_args=(--product RenderingValidationPackageTests)
if [[ "${ADAENGINE_VALIDATE_SPONZA:-}" == "1" ]]; then
  ada_validation_package_args+=(--include-sponza-demo)
  ada_validation_product_args=(--build-tests)
fi
ada_validation_package="$("$ada_validation_python" script/gpu_validation_package.py "${ada_validation_package_args[@]}")"
# The GPU suites share one process-wide renderer, so the validation package runs its tests one at a time.
ada_validation_filter='PluginLoadingTests|WESLShaderModuleTests|WESLGradientPipelineTests|WESLUIPipelineTests|WGSLReflectionTests|ShaderGraph|SpriteGraphs|SpriteMetalRenderingTests/rendersLayoutsAndPickingWithSAGA|SpriteMetalRenderingTests/rendersTileOcclusionWithSAGA|BoundedResourceCacheTests|RenderGraphDiagnosticsTests|WindowFrameRequestsTests|MaterialUploadReuseTests|OptionalResourceTests|RenderUpscalingTests|Render3D|GoldenFrameComparisonTests|GoldenBackendAgreementTests|VisibleMesh3DListsEquivalenceTests'
ada_validation_filter="$ada_validation_filter|Particle3DTests"
ada_validation_filter="$ada_validation_filter|ColorCurves3DTests"
ada_validation_filter="$ada_validation_filter|SAGAMetalNativeSubmissionTests"
ada_validation_filter="$ada_validation_filter|SAGAMetalResourceDeviceTests|SAGAMetalFoveationTests|TextureImportSettingsTests/sagaMetalInitializesEveryCubeFaceAndMipLevel"
ada_validation_filter="$ada_validation_filter|SAGAVulkanDeviceTests"
ada_validation_filter="$ada_validation_filter|SAGAIndexedIndirectTests"
ada_validation_filter="$ada_validation_filter|SAGAVisibilityProcessorTests"
ada_validation_filter="$ada_validation_filter|MeshBufferTests|TextShaderRenderingTests"
ada_validation_filter="$ada_validation_filter|Foveated3DRenderingTests"
ada_validation_filter="$ada_validation_filter|PixelPerfectMetalTests"
ada_validation_override="${ADAENGINE_GPU_TEST_FILTER:-}"
ada_validation_filter="${ada_validation_override:-$ada_validation_filter}"
if [[ "${OS:-}" == "Windows_NT" ]]; then
  export ADAENGINE_SHADER_SOURCE_ROOT="$(cygpath -m "$ada_validation_root")"
  # Building the test product avoids compiling unrelated dependency command
  # plugins (JavaScriptKit's PackageToJS currently cannot compile on Windows).
  swift build "${ada_validation_build_args[@]}" --package-path "$ada_validation_package" "${ada_validation_product_args[@]}" \
    --disable-sandbox --scratch-path "$ada_validation_scratch"
  ada_windows_test_log="$ada_validation_scratch/windows-gpu-tests.log"
  swift test -c "$ada_validation_configuration" --package-path "$ada_validation_package" --skip-build --scratch-path "$ada_validation_scratch" \
    --no-parallel --filter "$ada_validation_filter" 2>&1 | tee "$ada_windows_test_log"
  if [[ -z "$ada_validation_override" || "$ada_validation_override" == "SAGAVulkanDeviceTests" ]]; then
    for ada_window_test in offscreenResourcesWorkBeforePresentingToAWin32Window twoWindowsPresentAndTheFirstSurfaceCanBeRecreated; do
      if ! grep -Fq "Test $ada_window_test() passed" "$ada_windows_test_log"; then
        printf 'Windows GPU validation did not report a pass for %s. See %s\n' "$ada_window_test" "$ada_windows_test_log" >&2
        exit 1
      fi
    done
  fi
else
  swift test "${ada_validation_build_args[@]}" --package-path "$ada_validation_package" --disable-sandbox --scratch-path "$ada_validation_scratch" \
    --no-parallel --filter "$ada_validation_filter"
fi
