# DLSS upscaling — implementation plan

Design: [dlss-upscaling.md](../Designs/dlss-upscaling.md) (approved). Task id: `dlss-upscaling`.
Each stage ends with `check_contribution.py run`; Red → Green → Refactor evidence is recorded per testable stage.

| # | Stage | Result | Gate |
| --- | --- | --- | --- |
| 0 | Resolve open questions | Read SDK headers/`VulkanNativePassContext`; settle bridge module placement, RR guide conventions, Vulkan extension needs. Any required SAGA change returns to the human before Stage 3. | Written findings appended to the design (no behavior change) |
| 1 | Settings and selection (TDD) | `TemporalReconstructionMethod.dlss`, preset mapping from `renderScale`, `.automatic`/`.dlss` selection with a fake bridge, per-view status resource, Codable compatibility. | Swift Testing suite red → green |
| 2 | Bridge stub | `CNGXBridge` target that builds without the SDK and reports `unavailable(reason)`; `ada_tool prepare dlss` / `ADAENGINE_NGX_SDK_PATH` plumbing; `doctor` informational entry; safe library loading (executable dir or configured path only). | Stub builds on Windows and Linux; `python script/test_ada_tool.py` |
| 3 | Vulkan interop | `VulkanInterop` over `NativePass` (ownership checks mirror `MetalInterop`), with a recording test double. | Unit tests; SAGA Vulkan validation passes |
| 4 | DLSS Super Resolution | Real NGX calls behind the bridge; `DLSSTemporalUpscaler.encode`; device factory returns it when available; feature create/release on resize, scale change and reset. | `ADAENGINE_DLSS=1` smoke on the RTX 4070; fallback tests without SDK |
| 5 | Ray Reconstruction | `supportsDenoising` and `encodeDenoised` with `RayReconstructionGuides`; verify the path tracer selects it and reports `denoiser: rayReconstruction`. | Smoke on a path-traced scene |
| 6 | Documentation | `Articles/3D/DLSSUpscaling.md` + navigation; fix `Documentation/PathTracing.md` and `saga-native-render-layer.md` Stage D; example compiled in a test; offline-docs check if affected. | DocC build, `documentation` command checks |
| 7 | Review | `check_contribution.py run --stage review`; independent `adaengine-review` subagent; fix findings. | `verify --stage done` |

Ordering notes: Stages 1–3 need no SDK and can land and be validated on any machine; Stages 4–5 need the NGX SDK and an
RTX GPU (blocked, not skipped, elsewhere). Task-owned files are recorded with `init` and extended with `scope` as
files are created.
