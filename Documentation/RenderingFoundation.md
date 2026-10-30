# Diffuse transport, shadows and portable temporal reconstruction

2026-10-30. These optional features extend the existing Metal/WebGPU graph.
The remaining rendering gaps and acceptance criteria live in
[ADR-0027](ArchitectureDecisions/0027-3d-rendering-pipeline-gap-roadmap.md).
DLSS remains the native Windows RTX path; see [DLSS](DLSS.md).

```swift
environment.screenSpaceGI = ScreenSpaceGI3D(isEnabled: true, rayCount: 8, stepCount: 16)
environment.contactShadows = ContactShadows3D(isEnabled: true)
environment.shadows.filter = .pcss
environment.shadows.lightAngularRadius = 0.27 // degrees, emitter angular radius

// TAA at native resolution. Use renderScale 0.67 for temporal upscaling.
camera.temporalUpscaling = .init(renderScale: 1, method: .portable)
// The default .automatic still selects native DLSS/MetalFX and preserves its fallback.

environment.fog.isEnabled = true
environment.fog.volumetric.isEnabled = true
environment.fog.volumetric.localLightLimit = 4
environment.fog.localVolumes = [LocalFogVolume3D(
    minimum: [-2, 0, 3], maximum: [2, 3, 8], density: 0.08, edgeFade: 0.25)]
```

## SSGI

One diffuse bounce of visible direct illumination and emission. A cosine-weighted
hemisphere is traced against the current view-position buffer; hit radiance has
the existing indirect contribution removed. The real receiver base color,
metallic/Fresnel response and clearcoat attenuation come from an optional
RGBA8 surface attachment. A half-resolution normal/depth/material bilateral
filter and depth-aware upsample preserve surface boundaries. Result composition
is in linear HDR before exposure and tone mapping. SSAO attenuates it as
indirect illumination. Existing IBL and hybrid SSR stay enabled.

The current bloom source and auto-exposure meter use the earlier scene buffer;
the added diffuse bounce does not feed those two measurements yet.

Limits: 1–16 rays, 4–32 steps, one bounce, opaque receivers, visible geometry
only. Hidden/off-screen surfaces, paths behind the camera and hardware RTGI are
outside this method. Thin geometry and disocclusion can reveal screen-space
errors. The pass has spatial filtering; selected TAA/DLSS can stabilize the
finished image, but there is no separate temporal GI reservoir or denoiser.
Devices must support six attachments and 48 attachment bytes/sample. Unsupported
devices retain existing ambient lighting. Disabling GI releases its targets and
encodes no GI pass. At 1080p the surface attachment and two half-resolution HDR
targets together take about 16.6 MB, excluding the bounded cache of resized targets.

## Shadows

PCSS searches 16 blockers, estimates world-space receiver/blocker separation
from the directional shadow matrix and filters 24 comparison taps. Angular
radius controls emitter size; both search and penumbra are bounded. Every tap
stays inside its cascade. Directional cascades remain conventional maps;
local shadow maps keep PCF. This is not Virtual Shadow Maps or ray-traced shadows.
The default remains the original PCF.

Contact shadows march toward the actual primary directional source and up to
four local sources assigned shadow-atlas slots. They multiply only those direct
BRDF terms, respecting receive/cast flags, range and spotlight cone. Ambient,
emission and unshadowed lights retain their lighting. A camera-depth prepass
reuses the shadow vertex, skinning, morph and alpha-test paths; blends are
excluded. The R32F depth copy supports nonfilterable sampling. Maximum 32 steps,
2 m ray length, distance fade. Off-screen occluders are absent. Foveated views
skip this supplement. At 1080p its color/depth pair takes approximately 25 MB
plus an additional geometry pass; disabled views allocate neither target.

## Local volumetrics

Up to eight overlapping world-axis-aligned boxes add density and scattering
albedo to global height fog, with a soft edge. They work with global density
zero. The half-resolution ray march evaluates up to eight point/spot lights
(four by default), inverse-square/range/cone attenuation, phase and actual
point/spot shadow-atlas visibility. Lights without a shadow slot scatter
unshadowed, matching their surface shadow allocation. A sun is optional.
Global sun-only integration and its golden frames retain their earlier behavior.
Local extinction is stored separately in alpha so the analytic global fog is
not applied twice. Local boxes respect sky influence.

This is single-scattering homogeneous local fog: no froxel history, multiple
scattering, oriented shapes or animated density textures. The finite march
range/step count can miss a very thin distant volume. Light budget follows the
existing bounded light selection; it is not a per-froxel cluster.

## Portable TAA / temporal upscaling

Shader reconstruction uses the existing eight-sample jitter sequence and
camera, rigid, skeletal, morph and sky motion. Foreground depth dilates motion;
previous projected depth rejects disocclusion. History is clipped to the current
3×3 YCoCg neighborhood, with reactive transparency and movement weighting.
HDR brightness is compressed during the weighted blend. Each camera owns two
HDR color and R32F depth histories; resize, camera cuts, discontinuity, method
changes and reset generation invalidate history. UI is composited afterwards.

This is a basic temporal reconstruction path, not an assertion of TSR/DLSS
quality. Fine transparency/particles, lighting changes and low input resolution
still need scene-specific artifact review. Two color/depth history pairs take
approximately 49.8 MB at 1080p in addition to common temporal targets. Explicit
`.portable` selection keeps DLSS availability reporting and native fallback
semantics unchanged.

Actual WebGPU verification is in `Render3DGPUTests/LightingFoundation`,
`Render3DGPUTests/ShadowFiltering`, `Render3DGPUTests/Fog` and the existing
DLSS/history suites. Last Autumn includes opt-in executable presets and captured
evidence in `Evidence/RenderingFoundation`; default scenes keep their prior
feature settings. Metal source support has not been accepted on Apple hardware
by this Windows run.
