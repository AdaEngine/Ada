# DLSS Super Resolution and Ray Reconstruction on SAGA Vulkan

Status: **Amended after approval — the amendments below await explicit human approval.**
Classification: feature (a new native upscaler integration, built on the existing `TemporalUpscaler` seam).
Related: [SAGA as AdaRender's only backend](saga-native-render-layer.md) (Stage D),
[SAGA renderer cutover](saga-renderer-cutover.md), [Path tracing denoising](path-tracing-denoising.md).

## Amendments

Accepted by the maintainer during implementation and review; the text below overrides the sections it names.

1. **Bridge delivery (SDK delivery, Alternatives).** NGX is a static C++ library, so it cannot be loaded by symbol. DLSS
   ships as a separate, optional bridge library, `adaengine_ngx`, whose source lives in `Tools/NGXBridge` and which
   `python ada_tool.py build ngx-bridge --sdk PATH` builds against a locally installed SDK. The engine loads it at run
   time from `ADAENGINE_NGX_SDK_PATH` or next to the executable, together with `nvngx_dlss.dll`. There is no stub
   SwiftPM target: without the bridge the status reports `unavailable` with a reason. `doctor` and `prepare` do not
   know about the SDK.
2. **Platform (Goals, Platform table, Documentation).** Windows with NVIDIA RTX is the only supported platform for now.
   Linux is deferred; the bridge, session and docs are Windows-only.
3. **`.automatic`.** It resolves to DLSS when available and to the builtin `.portable` reconstruction otherwise,
   including while DLSS is still initializing. Every camera with temporal upscaling set to `.automatic` therefore uses
   DLSS on RTX machines with the bridge installed.
4. **Failure scope.** A run-time DLSS failure turns DLSS off for the whole session (every view); the failing frame keeps
   its previous output.
5. **SAGA.** SAGA gained `VulkanExtensionRequest` (merged to SAGA `main`) so the host can have NGX's Vulkan extensions
   enabled when the instance and device are created.

## Problem

The legacy Swan/Dawn backend carried DLSS. It was removed with the cutover, so NVIDIA GPUs on Windows and Linux now
get only the vendor-independent portable temporal upscaler and the portable path-tracing denoiser. The engine still
contains the DLSS-shaped seams: `TemporalUpscaler` (with `supportsDenoising` / `encodeDenoised`),
`RayReconstructionGuides`, `TemporalUpscalingSettings.method`, `target.rayReconstructionAvailable`, and the
`PathTracingDenoiser.rayReconstruction` case with its "unavailable" fallback. Nothing implements them, so those paths
are dead.

## Facts established in the repository (2026-11-16)

- `RenderDevice.createTemporalUpscaler(inputSize:outputSize:)` returns `nil` on SAGA. `Temporal3DHistory` selects
  `PortableTemporal3DUpscaler` for `.portable` and the device factory otherwise.
- SAGA already provides the hook the cutover design listed as missing: `NativePass` with
  `VulkanNativePassContext` (instance, physical device, device, queue, queue family, command buffer in the recording
  state, and `VkImage`/view/format/extent per named resource; images stay in `VK_IMAGE_LAYOUT_GENERAL`; SAGA places full
  memory barriers around the body). A Metal equivalent exists and AdaEngine already uses it (`SAGAMetalNativeSubmission`,
  `MetalInterop`). AdaEngine has no Vulkan counterpart yet.
- `saga-native-render-layer.md` still describes the hook as a SAGA prerequisite. This design supersedes that statement.
- Windows and Linux render through SAGA Vulkan; D3D12 exists in SAGA but is not consumed by AdaEngine.

## Goals

1. NVIDIA GPUs on Windows and Linux can use DLSS Super Resolution for 3D cameras, with the existing per-camera
   `TemporalUpscalingSettings` model.
2. DLSS Ray Reconstruction denoises the path tracer when Super Resolution is active for the view, using the existing
   guides.
3. Everything degrades to the portable paths when the SDK, GPU, driver or view is unsupported, with a visible reason.
4. No SDK binary or license-restricted file enters the repository.

## Non-goals

- DLSS Frame Generation / Multi Frame Generation.
- D3D12 (a later addition if AdaEngine adopts the SAGA D3D12 backend; the design keeps the NGX wrapper API-neutral
  where cheap, but implements and tests Vulkan only).
- macOS, iOS, Android, browser (they keep MetalFX/portable/FSR as today).
- Changing the portable upscaler or denoiser, or their golden frames.

## Proposal

### Layering

- **`CNGXBridge` (new C target, AdaRender or a sibling `AdaDLSS` module, decided in Plan):** a thin shim over the NGX
  Vulkan API (`NVSDK_NGX_VULKAN_*`). It never links the SDK statically. It `LoadLibrary`/`dlopen`s the NGX runtime at
  startup and reports `unavailable(reason)` when the library, a compatible driver, the feature (`SuperSampling`,
  `RayReconstruction`) or an entitlement is missing. All entry points return error codes; no `fatalError`.
- **`VulkanInterop` (AdaRender, SAGA backend adapter):** the Vulkan counterpart of `MetalInterop`. Converts the AdaRender
  textures of a call into `NativePass.Use` entries and exposes the `VulkanNativePassContext` handles to the closure.
  Resources not owned by this renderer are rejected (same `foreignResource` rule as Metal).
- **`DLSSTemporalUpscaler` (AdaRender):** implements `TemporalUpscaler`. One instance per source camera (history is
  owned by NGX feature handles). `encode` records a `.native` pass that evaluates Super Resolution with the jittered
  color, depth, motion and reactive textures and the existing jitter/reset. `supportsDenoising` is true only when the
  Ray Reconstruction feature was created; `encodeDenoised` evaluates it with `RayReconstructionGuides`.
- **`RenderDevice.createTemporalUpscaler`** on the SAGA Vulkan device returns a `DLSSTemporalUpscaler` when the bridge
  reports availability and `nil` otherwise. Unsupported backends still return `nil`.

Frame sequencing: NGX records into SAGA's command buffer inside the native pass; SAGA's barriers make prior passes'
writes visible and later reads see the output. The body must restore `GENERAL` layout (already the contract). Feature
handles are created and released on the render thread outside submissions that use them.

### Selection semantics

- `TemporalReconstructionMethod` gains `.dlss`. `.automatic` picks DLSS when available and the portable upscaler
  otherwise (today `.automatic` means "device upscaler or spatial fallback"; the portable method stays explicit).
  `.dlss` requests DLSS and, when unavailable, falls back to the portable upscaler with a status reason rather than
  failing.
- `settings.renderScale` maps to NGX quality presets by nearest preset (DLAA at 1.0, Quality, Balanced, Performance,
  Ultra Performance), clamped to what NGX reports as supported. The raw scale stays authoritative for the render target
  size.
- Codable: the new case decodes; unknown future values keep the existing defaulting behavior. Existing scenes decode
  unchanged.
- Status: a per-view status (active method, quality preset, fallback reason) is published alongside the existing
  `PathTracing3DStatus` style resources and surfaces in Studio diagnostics.

### Ray Reconstruction

`PathTracingDenoiser.automatic` and `.rayReconstruction` already select it when `target.rayReconstructionAvailable`
(set from `scaler.supportsDenoising`) and the G-buffer first hit exists. No path-tracing code changes are expected
beyond what review of the guides' conventions finds (Open question 2).

### SDK delivery

- The NGX SDK/runtime is not committed. `python ada_tool.py prepare` gains an optional, explicit `dlss` component that
  records an SDK path in `.build-tools`, or the developer sets `ADAENGINE_NGX_SDK_PATH`. The build compiles the bridge
  against SDK headers only when a path is present; otherwise the module builds as a stub reporting `unavailable`.
- At runtime the engine finds `nvngx_dlss.dll` / `nvngx_dlssd.dll` (Windows) or the Linux equivalents next to the
  executable or in the configured path. Distribution of those redistributable DLLs by a shipping game is the game
  author's responsibility under NVIDIA's license; the article says so.
- `doctor` reports a missing optional SDK as informational, never as a required-dependency failure.

## Alternatives considered

- **Bundle the SDK in the repository:** rejected; license terms and repository size.
- **Separate DLL bridge process/library built outside SwiftPM:** rejected; the C shim with dynamic loading is smaller
  and keeps one build graph.
- **Super Resolution only, defer Ray Reconstruction:** rejected by the requirements decision; the guides and the
  denoiser selection already exist, so deferring leaves dead code.
- **Implement on D3D12 first:** rejected; AdaEngine does not use the D3D12 backend.
- **Golden-frame tests for DLSS output:** rejected; output is not deterministic across drivers and GPUs.

## Platform and compatibility impact

| Platform | Behavior |
| --- | --- |
| Windows, Linux with NVIDIA RTX + SDK | DLSS SR and RR available |
| Windows, Linux otherwise | Portable upscaler/denoiser; status reason |
| Apple, Android, browser | Unchanged |

Public API: one new enum case on `TemporalReconstructionMethod`; one new status value. Behavior of existing scenes is
unchanged except that `.automatic` now prefers DLSS on supported hardware (a visible quality/perf change, called out in
the article and changelog). Performance: the DLSS pass replaces the portable resolve and the portable denoiser
passes for that view; no new per-frame allocations on the engine side beyond NGX-owned history.

## Security and safety

The NGX library is loaded only from the executable directory or an explicit configured path, never from the current
directory or `PATH` search. Handle values coming from SAGA are used only inside the body and never stored. All NGX
errors are surfaced as unavailability, not traps.

## Acceptance criteria

1. With the SDK present on the RTX 4070 test machine, a camera with `method: .dlss` reports `active: dlss` and a
   preset, and renders a non-black image; a path-traced view reports `denoiser: rayReconstruction`.
2. Without the SDK (or on a non-NVIDIA device), the same scene renders through the portable paths, the status reason
   names the cause, and the existing portable golden frames are unchanged.
3. `.automatic` selects DLSS only when available; `.dlss` never throws or crashes when unavailable.
4. Resizing the window, changing `renderScale`, toggling the method and a `resetGeneration` bump recreate features and
   history without validation errors from Vulkan validation layers.
5. `python ada_tool.py doctor` is not failed by a missing optional SDK.
6. `python script/check_contribution.py` passes; SAGA Vulkan GPU validation still passes.

## Verification plan

- Unit (Swift Testing): settings/Codable (`.dlss`), preset mapping, selection and fallback logic with a fake bridge,
  status reporting, and stub-bridge behavior.
- GPU smoke gated by `ADAENGINE_DLSS=1` on SAGA Vulkan with the SDK: SR active, RR active on a path-traced scene,
  output not black, no validation errors. Recorded as hardware evidence; not a golden comparison.
- Existing portable upscaling and path-tracing suites run unchanged as the fallback regression check.
- Hardware evidence is blocked (not skipped) on machines without an RTX GPU; the report must say so.

## User documentation delivery plan

- Audience: game developers using 3D cameras and path tracing.
- Source: new `Sources/AdaEngine/AdaEngine.docc/Articles/3D/DLSSUpscaling.md`, linked from the 3D topic group of the
  AdaEngine DocC catalog (exact Topics file resolved in Plan) and cross-linked from the path-tracing guide.
- Content: what DLSS SR/RR do, supported hardware and backends (Vulkan on Windows/Linux only), SDK setup and
  redistribution responsibility, enabling it per camera (`TemporalUpscalingSettings(method: .dlss)`) and for path
  tracing (`environment.pathTracing.denoiser`), reading the status/fallback reason, limitations (no Frame Generation, no
  D3D12/Apple/browser), cost and quality notes.
- Also update `Documentation/PathTracing.md` (it still says Metal/WebGPU) and `saga-native-render-layer.md` Stage D.
- Checks: example compiled in a test target; DocC build; `Editor/scripts/update-offline-documentation.py --check` if
  the offline guide changes.

## Open questions

1. Module placement of the C bridge (inside AdaRender vs a new optional `AdaDLSS` target) — resolved in Plan after
   checking SwiftPM target conventions on Windows.
2. Whether the existing `RayReconstructionGuides` conventions (albedo/normal/roughness packing, unjittered transforms)
   match NGX RR input expectations without extra passes — verified early in implementation with the SDK headers.
3. Whether `VulkanNativePassContext` exposes the required Vulkan instance/device extension requirements NGX needs
   (`vkGetDeviceProcAddr` access and extension enablement at device creation). If SAGA must enable extra extensions, that
   is a small SAGA change and is returned to the human before proceeding.
