# SAGA as AdaRender's only backend: collapsing RenderEngine and RenderBackend

Status: **Proposed — awaiting explicit human approval.**
Classification: improvement of an existing subsystem (AdaRender runtime layer), staged over several changes.
Related: [SAGA renderer cutover](saga-renderer-cutover.md), [SAGA migration](saga-migration.md),
[WESL built-in shader migration](wesl-builtin-shader-migration.md).

## Problem

AdaRender still carries three generations of backends behind one `RenderBackend` protocol: legacy Metal, Swan/Dawn
WebGPU, and the SAGA adapters (browser, native Vulkan, Apple Metal), plus headless. Backend selection is a compile-time
`#if` ladder in `RenderEngine.setupRenderEngine()`, 30 call sites branch on `RenderEngine.shared.type`, and platform
features (upscalers, GPU culling) live inside individual backends. Once SAGA is the only GPU runtime, most of that
indirection has no purpose. The question is how far to collapse it without losing headless operation or the
platform-specific features (DLSS, MetalFX) that SAGA does not express today.

## Current state (verified in the repository on 2026-11-13)

- `RenderEngine` is a thin facade (242 lines) that forwards to one `RenderBackend`; it is referenced in 84 files.
  `RenderBackend` itself is referenced in 9 files and has window create/resize/destroy, a global `RenderDevice` and
  `createLocalRenderDevice()` (no caller outside the backends was found; confirm before relying on this).
- `RenderDevice` (89 files) and `RenderCommandEncoder` (26 files) are AdaEngine's own stateful API (`createBuffer`,
  `createTexture`, `setPipeline`, `draw`). SAGA is different: an async `Device` actor that takes declarative command
  lists, with a `BackendDevice` protocol per native backend. The adapters (`Backends/SAGA`, 2,367 lines) bridge the two.
- Backend implementations in the tree: Metal 2,986 lines, WebGPU/Swan 6,082, OpenGL 1,057 (no `RenderBackendType` case
  references it; likely dead), SAGA 2,367, Headless 317.
- Headless (`HeadlessRenderBackend`) has no device: no-op resources and window bookkeeping. SAGA has no headless or
  null device. Shader compilation also special-cases `.headless` (`ShaderCompiler.swift`).
- Platform features are optional factories on `RenderDevice`: `createTemporalUpscaler`, `supportsSpatialUpscaling`,
  GPU visibility / meshlet / shadow-cull processors, multi-draw-indirect flags. Unsupported backends return `nil` and the
  engine falls back (CPU culling, spatial fallback). MetalFX is in the Metal backend; DLSS goes through Dawn interop in
  the WebGPU backend; FSR 1 and a portable temporal upscaler are shader passes.
- SAGA has no upscaler or native-interop concept.

## Goals and non-goals

Goals:

1. After the legacy backends are removed, replace `RenderBackend` and the `#if` ladder with one concrete engine type
   and per-platform SAGA contexts. Remove the 30 backend-type checks in favor of capabilities.
2. Keep headless working with no GPU, including CI.
3. Give MetalFX and DLSS a supported integration point instead of backend-private code, with portable fallbacks.
4. Preserve public API and behavior until each step is proven; keep a deprecation path for public enum cases.

Non-goals:

- Rewriting `RenderDevice`, the encoders, the render graph or the render nodes onto SAGA types. That is a separate,
  later decision (Stage E) that needs profiling evidence.
- Changing the shader pipeline (covered by the WESL migration) or the platform defaults (covered by the cutover plan).

## Proposal

### Stage A — prerequisite (already planned elsewhere)

Finish SAGA parity and delete legacy Metal, Swan/Dawn WebGPU, OpenGL and GLSL per the cutover plan and the WESL
migration. This design starts to apply only when a platform has no legacy backend left. Nothing here changes runtime
backend selection before then.

### Stage B — collapse the thin layer

- Replace the `RenderBackend` protocol and `RenderEngine` forwarding with one concrete `RenderEngine` that owns an
  internal `RenderHost` (window registry, global device, optional SAGA `Device`). Per-platform SAGA contexts
  (browser, Vulkan, Metal) are chosen by one factory per platform instead of the shared `#if` ladder.
- `RenderBackendType` stays public. `.metal` and `.webgpu` are deprecated and map to the platform's SAGA path;
  `.saga` and `.headless` remain. (Open question 3.)
- Replace `RenderEngine.shared.type` checks with a small capabilities value (shader input is always WGSL; `isHeadless`;
  feature flags that already exist on `RenderDevice`). No call site may switch on a backend case afterward.
- `createLocalRenderDevice()` is removed if the confirmation in "Current state" holds; otherwise it stays on the host.

### Stage C — headless

Headless means "no graphics device", and several systems rely on that (CI, servers, the Studio CLI, tests). Two options:

- **C1, null device in AdaRender (smallest):** keep `HeadlessRenderDevice` as the host's device when no SAGA context
  exists. No SAGA change; behavior is unchanged from today.
- **C2, headless backend in SAGA (recommended end state):** add a `SAGAHeadless` `BackendDevice` that validates and
  discards submissions. The same adapter code runs with no GPU, so GPU-validation errors surface in CI, and headless
  stops being a special case in shader compilation. Needs a SAGA repository change (cross-repo prerequisite).

Plan: C1 ships with Stage B; C2 replaces it when SAGA provides it. (Open question 1.)

### Stage D — platform extensions (MetalFX, DLSS, FSR)

- SAGA gains an **external pass** hook: a callback that receives the backend-native command buffer plus native handles for
  the named textures (`MTLTexture`, `VkImage`, `ID3D12Resource`), while SAGA keeps ownership of barriers, resource states
  and lifetimes across queued work. This is a SAGA repository change and a hard prerequisite for MetalFX and DLSS on SAGA.
- MetalFX (spatial and temporal) and DLSS (NGX, Vulkan and D3D12) become optional AdaEngine targets implementing the
  existing `TemporalUpscaler` protocol and the spatial-scaler path against that hook. They keep the packaging they have
  today (DLSS is already an optional native artifact) and report unavailable when the hook or the SDK is missing.
- FSR 1 and the portable temporal upscaler are ordinary shader passes on SAGA and need no interop; they are the
  documented fallback everywhere the native upscalers are missing. DLSS on Windows stays out of scope until the
  external pass is verified, as the cutover plan already states.

### GPU feature processors

GPU visibility, meshlet, shadow-cull and multi-draw-indirect support are backend-private today. Because each factory
already returns `nil` on unsupported backends, deleting a legacy backend degrades to the CPU path rather than failing.
Before a platform loses its legacy processor, a SAGA compute implementation or a measured acceptance of the CPU fallback
is required (use the ADR-0027 benchmark).

### Stage E — thin `RenderDevice` toward SAGA (deferred)

Out of scope for this design. Revisit only with profiling evidence that the adapter layer is a bottleneck or a source of
defects. It would need its own design.

## Alternatives considered

- **Replace `RenderDevice` and the encoders with SAGA directly now:** rejected. It rewrites the render graph and every
  render node (84 + 89 + 26 file references), mixes two programming models (stateful immediate encoders against async
  declarative lists) and delivers no capability that Stages B to D do not.
- **Keep `RenderBackend` as is:** rejected for the long run. After Stage A it has two implementations and exists only to
  hold the `#if` ladder and 30 type checks.
- **Keep per-backend DLSS/MetalFX code inside AdaRender:** rejected; SAGA owns the native command buffers and resource
  states, so backend-private encoding would fight SAGA's lifetime and barrier tracking.
- **Make headless a compile-time flag only:** rejected; CI and tools need it at runtime, and a recording backend is a
  better test seam than no device.

## Platform and compatibility impact

- Apple: SAGA Metal replaces legacy Metal; MetalFX needs the external-pass hook. Validation owner is a contributor on
  Apple hardware.
- Windows, Linux, Android: SAGA Vulkan; DLSS needs the hook and NGX; Android continues to follow the cutover plan.
- Browser: SAGA WebGPU host; FSR and portable temporal upscaling only (no native upscalers).
- Public API: `RenderBackendType.metal` and `.webgpu` deprecated with a mapping; `RenderEngine.configurations` keeps
  its shape. Games that never name a backend are unaffected.

## Acceptance criteria

1. Stage B: no `#if` backend-selection ladder, no `RenderBackend` protocol, no switch on a backend case outside the
   platform factory; golden-frame suites unchanged on every platform where they ran before.
2. Stage C: headless test and CLI runs pass with no GPU; with C2, a shader or pipeline validation error fails a headless
   CI job.
3. Stage D: MetalFX and DLSS run through the external-pass hook behind explicit flags, fall back to FSR or the portable
   upscaler when unavailable, and are covered by readback comparisons on their native hosts (recorded as not covered
   where the hardware is missing).
4. Performance: the ADR-0027 benchmark shows no regression beyond a threshold the human sets (Open question 6) before
   any legacy processor is deleted.
5. A superseding decision is recorded for earlier ADRs that promised the old interfaces, rather than rewriting them.

## Test plan

Each stage follows Red, Green, Refactor. Stage B: tests that fail while a switch on a backend case remains (a
repository-level check), plus capability tests. Stage C: headless-device contract tests shared by C1 and C2. Stage D:
fake external-pass tests on the host, then native readback tests on Apple and NVIDIA hardware. Unavailable hardware is
reported as blocked, not passed.

## User documentation delivery

- Add a developer DocC article on render backends and capabilities (what runs where, how to select headless, how to opt
  into MetalFX or DLSS and what the fallbacks are) under `Sources/AdaEngine/AdaEngine.docc/Articles/Developers/`, linked
  from `AdaEngine.md`, and update `WESLShaders.md` where it mentions backends.
- A migration note for the deprecated `RenderBackendType` cases belongs in the same article.
- Docs checks: DocC builds and the article's code samples compile.

## Open questions for the human

1. Headless: ship C1 now and plan C2, or wait and do C2 only? (Recommended: C1 now, C2 when SAGA has it.)
2. Is the SAGA external-pass API an accepted cross-repo prerequisite, and who owns its design on the SAGA side?
3. Keep `RenderBackendType.metal` and `.webgpu` as deprecated aliases for one release, or remove them at once?
   (Recommended: deprecate for one release.)
4. May `createLocalRenderDevice()` be removed if no caller turns up?
5. Should DLSS and MetalFX ship as separate SwiftPM targets so apps that do not use them carry no SDK dependency?
   (Recommended: yes.)
6. What performance threshold gates deleting each legacy GPU processor? (Proposal: no more than 3% frame-time
   regression on the ADR-0027 benchmark.)
