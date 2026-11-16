# Hardware path tracing — implementation plan

Design: [hardware-path-tracing.md](../Designs/hardware-path-tracing.md) (approved). Task id: `hardware-path-tracing`.
Each stage ends with `check_contribution.py run`; Red → Green → Refactor evidence is recorded per testable stage.
GPU checks run from a small scratch package on this host (the full test target crashes the Windows compiler); stages
that need hardware are blocked, not skipped, on machines without an RTX-class Vulkan device.

| # | Stage | Result | Gate |
| --- | --- | --- | --- |
| 0 | Spike: one ray from a fragment shader | Smallest end-to-end proof on the 4070 through SAGA directly: build a one-triangle bottom-level and a one-instance top-level structure, bind the top-level structure in a fragment pipeline compiled from WGSL/WESL, trace one ray, read back the hit. Also settles what the bottom-level build needs from the vertex buffer (layout, stride, compact position copy). | A recorded result. If SAGA must change, stop and return the deviation to the human. **Done 2026-11-16, no SAGA change needed:** a fragment shader on the RTX 4070 bound a top-level structure through the render command's texture map (`textures: [slot: top]`) and a ray query hit the aimed pixel (kind 1, t 4, `instance_custom_data` equal to the instance ID) and missed the other. The bottom-level build takes `vertexOffset`, `vertexStride` (>= 12, multiple of 4) and optional 16/32-bit indices, so a separate position stream needs no compact copy. Spike test: `Tests/SAGAFoundationTests/VulkanFragmentRayQueryTests.swift` on the local SAGA branch `spike-fragment-ray-query` (uncommitted). |
| 1 | Settings, status and selection (TDD) | `PathTracingIntersection` (`.automatic`, `.software`) on `PathTracing3D` with Codable round trip and legacy decode; `PathTracing3DStatus.intersectionFallback` and the `implementation` values; pure selection logic (`device support`, `scene traceable`, `budget`) returning the traversal and a reason. | Unit tests, Red first. |
| 2 | AdaRender ray-tracing API (TDD) | `AccelerationStructure` resource, bottom-level and top-level creation and build commands, the resource-set binding kind, `RenderDevice.supportsRayQueries` (false by default); input validation; headless and fake devices report unsupported. ADR for the API. | Unit tests against a fake device; ADR drafted. |
| 3 | SAGA implementation | `SAGARenderDevice`/`SAGACommandBuffer` map the API onto SAGA's acceleration-structure resources, builds and the `acceleration_structure` binding; capability `rayQuery` drives `supportsRayQueries`. Resource lifetime follows SAGA's submission retirement. | GPU test on the 4070: build, bind and a trace in a test pipeline; no device errors. |
| 4 | Acceleration-structure owner (TDD) | Core pipelines resource that caches bottom-level structures per mesh part identity, orders extracted instances so each instance's part is a contiguous run in the triangle table, builds the top-level structure only when transforms, visibility or the instance set change, and releases structures after their work retires. Instance ID = first triangle index. | Unit tests for ordering, ID/triangle mapping, cache lifetime and rebuild triggers with a fake device. |
| 5 | Shader variant | `path_tracing_3d.wesl` gets the ray-query variant of `intersectScene` (candidate loop with back-face, alpha-test, stochastic-alpha and ray-bias rules, mask for shadow casters, hit mapped to the triangle table). Pipeline selection per view; the BVH upload is skipped on hardware; failure falls back to software with a reason. | GPU comparison test: hardware versus software image, same scene and frames. |
| 6 | Fallbacks and integration | Skinned/morphed meshes, budgets, build or compile failures, toggle and resize; history restarts only on a traversal or scene change; DLSS Ray Reconstruction and the portable denoiser both run on hardware. | GPU tests for each fallback and the toggle/resize run; no validation errors. |
| 7 | Measure | The Sponza path-tracing benchmark (`ADAENGINE_PERF=1`) for both traversals; set the image tolerance from measured error. Decide the `.automatic` default per the performance criterion and report the numbers to the human. | Recorded numbers; human informed if hardware is not at least as fast. |
| 8 | Documentation | `Articles/3D/HardwarePathTracing.md` with a verified example, navigation in `AdaEngine.md`, offline snapshot regenerated, `Documentation/PathTracing.md` corrected, `documentation` declared in the runner. | Docs checks pass; offline snapshot verified. |
| 9 | Review | `check_contribution.py run --stage review`; independent `adaengine-review` subagent; fix findings; `verify --stage done`. | Blockers reported exactly, including host limits. |

Ordering notes: Stage 0 comes first because the fragment-stage path is unproven; Stages 1, 2 and 4 need no GPU and can be
validated on any machine; Stages 3, 5, 6 and 7 need an RTX-class Vulkan device and are blocked elsewhere. Do not run Swift
builds with the local SAGA override and commit `Package.resolved` afterwards without checking it: SwiftPM rewrites it.
Task-owned files are recorded with `init` and extended with `scope` as files are created.

## Results (2026-11-16)

Stages 1 to 8 are implemented; Stage 9 is the runner and the independent review.

- **Hardware matches software.** On the RTX 4070 the hardware and software images of the debug scene differ by about
  0.0004 mean channel error (tolerance 0.03), including after moving, adding and removing meshes, with an alpha-masked
  panel and a single-sided plane. A hardware failure falls back to software with its reason and an unchanged image.
  DLSS Ray Reconstruction denoises a hardware-traced frame.
- **Needed beyond the plan:** the WESL host validation (`WESLHostCompiler`, `WESLBackendCompiler`) now accepts ray queries,
  because it rejected `enable wgpu_ray_query` before the stage reached a device. The triangle table keeps one entry per
  index-buffer triangle (empty entries for degenerate ones) in hardware mode so a hit's primitive index addresses it.
- **Measurement (Stage 7).** Synthetic scene of 64 shared spheres (about 85 thousand triangles), 640 by 480, 2 bounces,
  unoptimized engine build, best of three, wall-clock ms per frame including CPU preparation (SAGA reports no per-pass
  GPU timing):

  | Samples | Materials | Static, software | Static, hardware | One sphere moving, software | One sphere moving, hardware |
  | --- | --- | --- | --- | --- | --- |
  | 2 | single-sided | 14.47 | 17.06 | 492 | 439 |
  | 2 | double-sided | 14.29 | 14.98 | 509 | 438 |
  | 8 | single-sided | 22.91 | 15.96 | 488 | 441 |
  | 8 | double-sided | 23.09 | 12.38 | 501 | 447 |

  Hardware is clearly faster when the trace dominates and when objects move, about equal for double-sided and slightly
  slower (up to about 18 percent) for single-sided materials at 2 samples. The Sponza benchmark was not available, so
  design criterion 7 is only partly established: `.automatic` selects hardware, and the result is reported to the human.
  The decision is one constant in `PathTracingTraversalSelection.select`.
- **Not exercised:** Vulkan validation layers, resize and scale-change runs, a release build, per-pass GPU timing, other
  GPUs, and the full test target (compiler crash on this host).
