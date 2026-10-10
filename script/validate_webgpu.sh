#!/bin/bash
# Always exercise Tint; do not silently accept cached WGSL or skip a missing tool.
set -euo pipefail
ada_validation_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ada_validation_root"
export TINT_EXECUTABLE
TINT_EXECUTABLE="$(python3 script/ensure_tint.py)"
export ADAENGINE_WEB_EXPORT=1 ADAENGINE_VALIDATE_TINT=1 ADAENGINE_SPRITE_WGPU_SMOKE=1
ada_validation_scratch="${ADAENGINE_WEBGPU_SCRATCH:-/tmp/adaengine-webgpu-dev-validation}"
ada_validation_package="$(python3 script/webgpu_validation_package.py "$ada_validation_scratch/validation-package")"
swift test --package-path "$ada_validation_package" --disable-sandbox --scratch-path "$ada_validation_scratch" \
  --filter 'TintToolchainTests|TintShaderCompilerTests|WGSLReflectionTests|SpriteMetalRenderingTests/rendersLayoutsAndPickingWithWebGPU|SpriteMetalRenderingTests/rendersTileOcclusionWithWebGPU'
