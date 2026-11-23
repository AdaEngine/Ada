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

## Ambient occlusion: SSAO and CORTAO

```swift
var environment = Environment3D()
environment.ambientOcclusion = ScreenSpaceAO3D(
    isEnabled: true,
    technique: .cortao,          // default .ssao
    temporalAccumulation: true,  // default; CORTAO only
    bentNormals: true            // default; CORTAO only
)
camera.components[Environment3D.self] = environment
```

`ScreenSpaceAO3D.technique` selects the algorithm for a camera: `.ssao` (default) or `.cortao`. Both write the
half-resolution AO target, share `radius`, `intensity`, `bias` and `sampleCount`, and use the same depth/normal
bilateral filter, so the rest of the frame does not change.

CORTAO (Circular Occluder Ray-Traced Ambient Occlusion, Daniel Isheden, MIT licence,
<https://github.com/theagentd/CORTAO>) treats nearby depth/normal samples as circular occluders and traces 16 rays
against them. It is more accurate than hemisphere SSAO on slanted surfaces and thin occluders. The port runs four
steps per frame:

1. A compute dispatch builds a four-level depth/normal pyramid (one RGBA16F texture with four mips; each level keeps
   one pseudo-random texel of every 2x2 block, as in the reference, and remembers which pixel it came from).
2. A fragment pass samples the pyramid on a golden-angle spiral and looks up which rays each occluder blocks in the
   occluder table, a 24 x 24 x 16 table of 16-bit ray masks generated at start-up.
3. With `temporalAccumulation` (default on) the pass uses a new random seed every frame, and a temporal pass blends
   the result into a reprojected history. History is rejected where depth changes and clamped to the current
   neighbourhood; very fast-moving objects can leave a faint trail. Turn it off for a fixed, noisier result.
4. The same depth/normal bilateral filter as SSAO.

With `bentNormals` (default on) CORTAO also writes a bent normal, the average direction of the rays that reach open
space. With image-based lighting the composite pass then looks up the diffuse light along that direction instead of
the surface normal, so a surface near an occluder takes on the colour of the open side, and it occludes reflections by
how much of their lobe sees open space (cone-cone intersection, Jimenez et al. 2016) instead of by the scalar AO. It needs
image-based lighting, compute passes and the lighting surface attachment; otherwise the scalar AO is used. The
`bentNormals` debug view shows it. Design: [cortao-bent-normals.md](Designs/cortao-bent-normals.md).

CORTAO needs a device with compute passes (`RenderDevice.supportsComputePasses`), a perspective camera and targets
of at least 8x8 pixels. SAGA Vulkan has been validated. SAGA Metal exposes compute passes and still needs runtime
validation. The renderer uses SSAO while the CORTAO compute pipeline initializes. Devices without compute support,
including the browser host, and other camera projections also use SSAO. Increase `bias` if self-occlusion makes a
curved mesh look blotchy. It lifts the shaded point along its surface normal. The pyramid stores depth in RGBA16F, which limits precision on grazing surfaces at long range; the normal offset
absorbs it at normal distances. With temporal upscaling the history lookup ignores the upscaler jitter, a sub-pixel
error that the neighbourhood clamp hides. Lightmapped and irradiance-grid surfaces keep the scalar AO. Not ported: the reference occluder and bent-normal look-up tables (the table is generated at start-up and the bent normal is summed directly).

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

Limits: 1â€“16 rays, 4â€“32 steps, one bounce, opaque receivers, visible geometry
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

### Shadow casting cost

Shadow maps are redrawn every frame they change; a moving point light redraws
all six of its faces. With WebGPU (native and browser), ordinary static casters
are culled on the GPU for every shadow view at once (point and spot faces, sun
cascades), so the CPU no longer culls them per view. The shadow image is
identical to the CPU-culled path.

- **Casters that stay CPU-culled:** skinned or morphing meshes, meshes with
  level-of-detail alternatives, meshes with a finite maximum draw distance,
  alpha-masked shader-graph materials, and meshes without 32-bit indices. Their
  per-view result depends on CPU state. Blended materials cast no shadows, as before.
- **Draw calls:** where the native adapter supports Dawn's multi-draw
  (`multi-draw-indirect` with `indirect-first-instance`), one call draws each
  group of meshes per view, which removes most of the CPU cost. Without it
  (the browser, or adapters lacking those features) each mesh is still one
  indirect draw per view, so the saving is small. Native Metal and headless keep
  the CPU-culled path.
- **Memory:** each static caster's vertex and index data is copied once into
  shared shadow buffers, one pair per vertex layout, with up to 50% headroom for
  growth (at least 64 KiB each), plus per-view buffers of the culled instances.
  A layout whose shadow geometry would exceed 256 MiB keeps the CPU path.
- **Switches:** `ADAENGINE_SHADOW_GPU=0` draws every caster on the CPU-culled path;
  `ADAENGINE_SHADOW_MULTIDRAW=0` keeps GPU culling but issues one draw per mesh.

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

For bounded media, sunlight is integrated across each step's shadow crossing
instead of treating its midpoint as entirely lit or dark. Signed shadow-depth
separation is normalized between cascades; adjacent steps reuse endpoint
samples. Only intervals whose endpoint visibility differs perform five
bisections, followed by exact Beer-Lambert integration of the lit prefix or
suffix. This resolves atlas silhouette discontinuities without adding sampling
noise or increasing the base ray count. The existing four-tap depth-aware
reconstruction remains unchanged. Thin shadows whose two crossings both lie
inside one interval can still be missed at a finite step count.

This is single-scattering homogeneous local fog: no froxel history, multiple
scattering, oriented shapes or animated density textures. The finite march
range/step count can miss a very thin distant volume. Light budget follows the
existing bounded light selection; it is not a per-froxel cluster.

## Portable TAA / temporal upscaling

Shader reconstruction uses the existing eight-sample jitter sequence and
camera, rigid, skeletal, morph and sky motion. Foreground depth dilates motion;
previous projected depth rejects disocclusion. History is clipped to the current
3Ã—3 YCoCg neighborhood, with reactive transparency and movement weighting.
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

## Display gradients near black

Display outputs use shared, screen-stable stochastic rounding before BGRA8
quantization. A common RGB threshold preserves channel ordering in warm shadows;
explicit normalized byte codes avoid implementation-dependent UNORM rounding
at half-code boundaries. Exact black and white remain unchanged. This runs
after tone mapping/LUT, and again after lens resampling in the non-copy camera
resolve. The HDR temporal input is untouched, and there are no additional
passes, textures, uniforms or CPU work. It replaces solid low-code color bands
with subpixel coverage, rather than raising ambient light or adding film grain.

`Render3DGPUTests/DisplayDither` verifies actual BGRA8 pixel endpoints, neighboring
codes, warm-gradient spatial means, channel ordering and at most one code of
per-pixel quantization error. It does not claim a higher-bit-depth display path.
