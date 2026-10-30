# Baked diffuse lightmaps and spatial irradiance probes

Implemented 2026-10-30, following ADR-0027. This is the baked part of GI on the
existing Metal/WebGPU surface pipeline; native acceptance was run on Windows
WebGPU. Apple hardware acceptance is still outstanding.

The static solution can now be extended with optional GPU relighting from
moving local lights, including off-screen bounce surfaces. See
[DynamicGI](DynamicGI.md) for that separate update/history contract. The
limitations below describe the static base and its immutable geometry paths.

## Lighting convention

Both lightmaps and probe SH describe **incident diffuse irradiance / pi** in
linear HDR, before receiver albedo/Fresnel, exposure or tone mapping. They
include sky visibility and static diffuse interreflection. Analytic direct
sun/point/spot lighting is evaluated at runtime and is not added to receiver
maps. Thus static and moving receivers share units without doubling direct
lighting. Specular IBL, local reflection projection, SSR and realtime shadows
remain independent. A metallic surface receives no baked diffuse lobe.

Baked diffuse replaces the previous diffuse ambient term. Material AO is not
multiplied into it a second time; it still affects the remaining environment
specular. Optional screen-space AO remains a separate runtime contact effect
and can over-darken already baked static detail if authored too strongly.
Without a specular IBL asset, a baked view skips the old unoccluded procedural
ambient/reflection approximation. Attach an IBL asset for environment specular.

Unlike the separate SSGI composite, these contributions enter the main HDR
color/indirect buffers and therefore participate in exposure metering and bloom.
SSGI subtracts the indirect buffer from hit radiance before its dynamic bounce.

## Runtime API

```swift
var reference = Model3DSource(source: "@res://Lighting/Room/Room-Lightmapped.glb")
reference.lightmapSource = "@res://Lighting/Room/Room.lightmaps"
reference.lightmapIntensity = 1
// Install reference on the static model owner, using its baked world placement.

let probes = try AssetsManager.loadSync(
    IrradianceProbeGrid3D.self, at: "@res://Lighting/Room/Grid.probegrid")
environment.irradianceProbes = .init(asset: probes, intensity: 1,
    normalBias: 0.08, visibilityBias: 0.04)
```

`Core3DPlugin` registers both asset types. The model sidecar maps document-global
material indices to textures and checks the derived model filename and UV1.
Each model instance clones only the affected PBR materials, sharing textures
without mutating imported materials. Skeletal models and LOD alternatives are
rejected for surface lightmaps; moving/skinned objects use the world-space grid.

For prepared native meshes, `PBRMaterial.lightmapTexture`, `lightmapScaleOffset`
(`xy` scale, `zw` offset), and `lightmapIntensity` provide the same binding.
A mesh without UV1 ignores this manual binding; the sidecar import fails clearly
instead of silently sampling a corner. Set the texture/settings to nil to return
to ordinary ambient. Static model transforms or source shading changes require
rebaking; a lightmap is not a transferable material texture for arbitrary placements.

## Offline pipeline

`Tools/3DAssets/bake_gi.py` needs NumPy, Pillow and clang++/g++. It builds a small
dependency-free CPU triangle BVH into `.build-tools/gi-baker`; no baker code or
CPU tracing enters the game executable. Inputs are a `.giscene` JSON:

```json
{
  "models": [{"file": "Room.glb", "name": "Room", "lightmap": true}],
  "sky": [0.12, 0.18, 0.28],
  "sun": {"directionToLight": [0.3, 0.8, -0.4], "radiance": [1, 0.95, 0.8], "intensity": 3},
  "lights": [{"position": [1, 2, 4], "radiance": [1, 0.7, 0.3], "intensity": 8, "range": 6}],
  "probes": {"origin": [-3, -0.5, -3], "spacing": [1, 1, 1], "counts": [7, 5, 9], "visibilityResolution": 16}
}
```

Model entries accept a `transform` with position/rotation/scale or a column-major
matrix. Use `lightmap:false` for static occluders that need not get a derived
receiver model. Spotlight entries additionally specify `direction`,
`innerConeAngle` and `outerConeAngle` in degrees. A sky can instead specify
authored sRGB `zenith`, `horizon`, `ground` plus linear `intensity`, matching the
procedural renderer; ordinary RGB arrays and `lower`/`upper` skies are linear.

```text
python Tools/3DAssets/bake_gi.py Room.giscene --output RoomGI --samples 64 --bounces 2 --probe-samples 512 --texels-per-meter 4
python Tools/3DAssets/bake_gi.py --verify RoomGI/Bake.json
python Tools/3DAssets/test_baked_gi.py
```

The tool preserves source GLBs and writes derived static meshes. Each opaque
triangle gets an independent, padded secondary-UV chart. Chart size follows
world-space area, density and a bounded per-chart size; a primitive exceeding
4096 atlas dimensions must be split. Original UV0, tangents, materials and
embedded textures survive. Existing UV1 AO is resampled onto the new charts;
other material textures must reserve UV1 for lighting. Maps are bilinear,
without a mip chain. Alpha records coverage. Extra derived geometry contains
separate vertices at chart boundaries, preserving the visible source shape.

Direct sky/analytic lighting and emission are evaluated at source triangle
centres. Bounded diffuse-transfer iterations feed independent cosine-weighted
receiver integration. Fine receiver textures still come from runtime PBR.
The source-radiance approximation can lose small sun/shadow/material detail on
large source triangles; subdividing source geometry or improving this integrator
is needed for higher-quality bakes. This is not a production path tracer.

## Grid and visibility

Each regular-grid probe contains nine RGB L2 SH coefficients of irradiance/pi.
The shader evaluates directional lighting with the receiver's world normal,
including its normal map, and blends up to eight nearby probes. An octahedral
distance-moment map, supersampled during bake, reduces weights of probes hidden
behind geometry. Near-zero visibility is rejected rather than forced to a
light-leaking minimum. Probes classified inside solid geometry have confidence
zero. A covered point with no visible valid probe stays dark; grid boundaries
fade to the prior ambient.

`normalBias` moves the visibility query off the receiver; `visibilityBias`
allows finite distance-map error. Tune them in world metres, not screen pixels.
Large values can leak light. Visibility is finite angular resolution (8, 16 or
32); thin geometry can still be missed. There is no relocation, adaptive brick
refinement, runtime rebake or ray-traced update. This is a regular baked probe
volume, not full APV, DDGI or Lumen.

## Formats, limits and cost

- `.lightmaps`: version 1, encoding `diffuse-irradiance-over-pi`, derived `modelFile`,
  material-index map descriptors. Non-directional; normal maps do not reorient
  its baked incident diffuse term, though runtime direct/specular still respond.
- `.probegrid`: version 1, encoding `sh9-diffuse-irradiance-over-pi`, origin,
  spacing, counts, visibility resolution and two map descriptors. SH atlas
  width is `9*nx`, height `ny*nz`; visibility atlas is `resolution*nx` by
  `resolution*ny*nz`. Row order is `z*ny+y`. SH basis/order and diffuse convolution
  are shared explicitly by `gi_transport.py` and `BakedDiffuse3D.glsl`.
- Raw files are little-endian RGBA16F. SH RGB can be signed; other lighting
  data must be finite and nonnegative. Filenames cannot escape the sidecar
  directory, byte counts/layouts are validated, dimensions are at most 4096,
  and a surface set is capped at 256 MiB. Grids allow 2–64 probes per axis,
  at most 4096 probes total and positive spacing.
- Static receivers normally read one lightmap sample. Full-confidence maps
  return before grid sampling. Other receivers use up to 72 SH coefficient
  and eight visibility fetches, with no new geometry pass or MRT. No per-frame
  CPU ray tracing, scene capture or SH rebuild occurs.
- Corridor day/night data uses 13.87 MiB per state: 39 maps, 1485 probes,
  1312 valid. Both states are preloaded by the demo (27.74 MiB HDR data plus
  ordinary geometry/textures). Source and derived geometry are separate assets.

Bake manifests hash input geometry/configuration, tool sources and outputs.
The game wrapper additionally fingerprints scene and day/night profiles and
verifies day/night geometry/UV identity before packaging. Checks require the
source repository; runtime packages use the already prepared textures.

## Accepted scope and remaining work

Four offline tests verify BVH occlusion, cosine energy/direct exclusion, a real
wall's probe visibility, derived UV1, source preservation and stale fingerprints.
Actual GPU tests verify per-texel lightmap color, replacement of diffuse IBL,
preserved direct/specular light, missing-UV fallback, moving receivers,
occluded/all-hidden probes, import of real corridor assets and malformed assets.
The focused renderer/history regression run passes 26 tests.
Three game-side asset tests additionally check packaged-input fingerprints,
corrupted-output rejection and repository relocation without ignored caches.

The corridor demo uses two **fixed** clear-midday/midnight lighting states.
Sunset, storms and arbitrary moving/recolored lights do not recompute this
static solution; SSGI supplies only visible dynamic bounce. Static alpha-masked
and blended geometry is excluded from the bake; no colored glass transport,
specular GI, directional lightmaps, adaptive probes or dynamic off-screen GI
is claimed. The previous full golden-suite baseline exception in ADR-0027
remains separate; its references were not changed for this delivery.
