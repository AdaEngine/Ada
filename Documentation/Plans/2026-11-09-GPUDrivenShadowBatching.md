# GPU-Driven Shadow Batching — Implementation Plan

Design: [gpu-driven-shadow-batching.md](../Designs/gpu-driven-shadow-batching.md), approved 2026-11-09.
Task: `gpu-shadow-batching` (`script/check_contribution.py`).

## Steps

| # | Step | Files | Check |
| --- | --- | --- | --- |
| 1 | `multiDrawIndexedIndirect` encoder requirement (WebGPU native; others return false), `supportsMultiDrawIndirect`, WebGPU feature request (`multiDrawIndirect` + `indirectFirstInstance`), `ADAENGINE_SHADOW_MULTIDRAW=0`, index buffers usable as copy sources | `AdaRender/Backends/CommandEncoder.swift`, `RenderBackend.swift`, `WebGPU/WebGPURenderDevice.swift`, `WebGPU/WebGPURenderBackend.swift`, `WebGPU/Misc/WGPURenderCommandEncoder.swift` | WebGPU pixel test: multi-draw equals separate indirect draws |
| 2 | `GPUShadowCullProcessor` protocol and data layout; WebGPU compute implementation | `AdaRender/Misc/GPUShadowCull.swift`, `WebGPU/Misc/WGPUShadowCullProcessor.swift`, `WGPUShadowCullShaders.swift` | Input validation unit tests; GPU test: culled set ⊇ CPU frustum set (A2) |
| 3 | `ShadowCasterRegistry3D`: eligibility, geometry pool (byte copies per vertex layout), draw groups, instance records, change bounds | `AdaCorePipelines/CorePipelines/ShadowCasterRegistry3D.swift`, `Core3DPlugin.swift` | Unit tests: eligibility, segments, change bounds, pool reuse/rebuild (A4) |
| 4 | Culling and drawing in both shadow nodes, with CPU fallback and per-face reuse | `GPUShadowCull3D.swift`, `RenderNodes3D/LocalShadow3DRenderNode.swift`, `RenderNodes3D/DirectionalShadow3DRenderNode.swift`, `LocalLighting3D.swift`, `Lighting3D.swift` | Shadow atlas parity GPU vs CPU path (A3); existing face-cache tests |
| 5 | Golden runs (A1) with GPU path on, multi-draw off, GPU path off; Sponza benchmark (A5) | — | `script/validate_webgpu.sh`; `Render3DGPUTests/SponzaBenchmark` |
| 6 | Docs: `Documentation/RenderingFoundation.md` Shadows, `Documentation/Tooling.md`, performance note | docs | Review |

## Implementation choices within the design

- **Geometry pool:** each mesh part's original vertex and index bytes are copied on the GPU into one shared
  buffer pair per vertex layout, instead of a converted fixed layout. The shadow pipeline variant is the one
  the CPU path already uses for that layout, so shaders are unchanged and the inputs are byte-identical.
  Meshes always use 32-bit indices; other index formats keep the CPU path.
- **Instance selection:** culling copies the first 128 bytes of each surviving instance record into a
  compacted per-view buffer, as the existing Hi-Z processor does. The shadow vertex shader is unchanged.
- **Opaque material independence:** instead of a new per-instance flag, opaque casters bind one opaque
  material buffer with matching sidedness per draw group. In opaque mode the shadow fragment shader reads only
  the sidedness and alpha-mode fields, which are equal within a group.
- **Compute shaders** follow the existing visibility processors: WGSL in `AdaRender`, created by the render
  device. Native Metal and headless return no processor and keep the CPU path (same image, no speedup).
- **Face reuse:** a point/spot face kept from an earlier frame is redrawn when a GPU-path caster changed
  inside it (old or new bounds against the face frustum), preserving today's partial redraw.
