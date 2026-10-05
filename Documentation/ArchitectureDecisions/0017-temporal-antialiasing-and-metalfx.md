# ADR-0017: Temporal antialiasing and MetalFX

- Status: Accepted
- Date: 2026-10-05
- Implementation: Partial (local foundation; not released)

## Implementation status

Last verified: 2026-10-05, native macOS/Metal on Apple M3 Pro. This slice is local
and uncommitted. MetalFX temporal reconstruction, HDR input/output, jitter,
camera/rigid/skeletal motion, reactive transparency, per-camera history and
spatial fallback are implemented. A separate mesh-motion pass favors initial
correctness and validation over minimizing GPU work. UI uses output-resolution
viewport/projection/clipping after resolve. Validation and measured limitations
are recorded in [MetalFXValidation.md](../../Demos/SkeletalGarden/MetalFXValidation.md).

Apple mobile, native UI overlay coverage and actual non-Metal GPU execution remain unverified. Dynamic
resolution, frame interpolation and portable temporal reconstruction remain
future slices. Large material/lighting discontinuities require an explicit
`resetGeneration` change by the scene owner.

## Context

The renderer already supports MetalFX spatial upscaling, spatial FXAA, HDR PBR,
IBL, SSR, cascaded directional shadows, SSAO, GPU skinning and CPU visibility/LOD.
Spatial filtering cannot reconstruct detail over time. Temporal reconstruction
requires camera, rigid-object and skeletal motion, consistent depth and jitter,
and history isolated by source camera and render world.

## Decision

Add opt-in temporal reconstruction to the 3D graph using backend-neutral
interfaces in AdaRender and an MTLFXTemporalScaler implementation in the Metal
backend. Keep spatial upscaling and FXAA available as fallbacks. Unsupported
backends/devices must render a complete frame without temporal history.

Use an eight-sample Halton jitter sequence in input-pixel units. Retain the
previous unjittered camera projection, object transform and skin palette; motion
vectors point from the current pixel to its previous position in top-left UV
coordinates. New or reappearing objects use their current transform and pose as
previous values. Depth uses the engine's forward 0...1 convention.

Resolve scene color before 2D/UI compositing. UI must not enter temporal history.
Histories and scalers belong to a stable source camera within one render world,
not to a transient extracted entity or an input/output size shared by cameras.
Reset on first use, camera cuts, resize, projection/quality changes, missing
frames, explicit reset requests and scaler recreation. Prune removed cameras.
GPU resources and pose/uniform buffers must survive their in-flight commands.

Temporal mode must support render-to-texture cameras as well as windows. The
actual input size follows device capability and configured render scale;
unsupported temporal scaling may use spatial scaling if available. Existing
scene data and the default non-temporal rendering behavior remain compatible.

Dynamic resolution, frame interpolation, MetalFX denoised upscaling and a
portable temporal reconstruction algorithm are subsequent slices.

## Implementation checklist

- [x] Backend capability query and additive temporal-scaler interface with safe fallback.
- [x] Per-camera input/output targets, jitter and explicit/automatic history reset.
- [x] Camera, rigid mesh and GPU-skinned mesh motion vectors with consistent coordinates.
- [x] Temporal resolve before UI, including render-to-texture and mixed 2D/3D graphs.
- [x] Focused history/motion/resize/fallback tests and real Metal static/moving captures.
- [ ] Platform proof for Apple mobile and non-Metal fallback; record unverified platforms.

## Validation requirements

Test two cameras with different projections/sizes and independent histories;
resize, disable/re-enable, camera cuts, missing frames and new/reappearing meshes.
Validate rigid and joint motion numerically and from actual GPU readback. Run
SkeletalGarden with a moving camera and animated character, compare spatial and
temporal captures at the same output resolution, inspect ghosting and edge
stability, and measure asynchronous frame/pass cost. Static screenshots alone
are insufficient temporal-quality evidence.

References: [Apple MetalFX](https://developer.apple.com/documentation/metalfx),
[Temporal AA and upscaling](https://developer.apple.com/videos/play/wwdc2022/10103/).

## Consequences

This is an accepted implementation direction, not evidence of shipped behavior.
Each slice must record its tested platform and remaining checklist items.
