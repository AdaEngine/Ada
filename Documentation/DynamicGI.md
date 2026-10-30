# Dynamic local-light irradiance probes

Implemented locally on 2026-10-30. This extends [baked GI](BakedGI.md) with GPU
relighting of static world-space surface paths. Point/spot lights can move,
turn, change color/intensity or switch off; bounce surfaces need not be visible
to the camera. It uses the existing renderer and local-light shadow atlas,
including Dawn/WebGPU D3D12, without a new graphics backend or hardware RT API.

## Data and runtime contract

`Tools/3DAssets/bake_probe_transport.py scene.giscene --output output` traces
32/64/128/256 Fibonacci-sphere directions per probe against the static opaque
scene. `Grid.proberays` describes the same origin/spacing/counts as `.probegrid`
and three RGBA16F maps: hit position/validity, geometric normal and linear
diffuse albedo. Texture row is `z*ny+y`, column is `x*samples+ray`.
The manifest includes bounds of the actual hit surfaces, which may extend
beyond the receiver grid. Runtime source selection includes lights affecting
those bounds even when the entire light is outside the camera frustum.

Each frame a new pass after local shadows and before the main PBR pass relights
a round-robin subset of probes. It evaluates current light position, range,
spot cone and color, Lambert diffuse reflection, and real shadow visibility at
the cached surface points. SH9 projection uses the same basis and diffuse
convolution as the static baker. Two per-view HDR SH targets keep history;
views do not share mutable histories. Main PBR adds dynamic diffuse to both
lightmapped and probe-lit receivers before exposure/bloom. Specular and direct
lighting retain their existing paths. SSGI should be disabled in this preset
to avoid estimating the same local-light first bounce twice.

```swift
environment.irradianceProbes = IrradianceProbeSettings3D(
    asset: staticGrid,
    dynamic: DynamicIrradianceSettings3D(
        transport: surfacePaths, probesPerFrame: 64, historyWeight: 0.15))
let lamp = PointLightComponent(intensity: 30, range: 8, indirectIntensity: 1)
let flashlight = SpotLightComponent(intensity: 40, range: 15, indirectIntensity: 1)
```

`indirectIntensity` defaults to zero and older component JSON remains valid.
Opt in dynamic sources only: lights already included in the static diffuse
bake would otherwise be counted twice. A source must hold a local shadow slot;
missing/disabled/over-budget shadow resources suppress its indirect injection
instead of leaking unoccluded light. At most four local shadow lights can
participate, within the existing 32-light selection budget. The normal shadow
priority still decides which sources own those slots.

Default 64 probes/frame refresh 1485 probes in at most 24 rendered frames
(about 0.4 s at 60 FPS), with 15% of the previous value retained at refresh.
Moving sources can therefore leave a short history trail. If no participating
lights remain, the whole dynamic field clears on the next rendered frame.
Replacing transport textures resets history; disabling the option releases
per-view textures and records no relighting pass. No CPU tracing or readback
is performed per frame. `Render3DDynamicGIStatistics` reports actual encoded
frames, probe updates, sweeps and participating source count; GPU timing is
available through `Render3DPerformanceMetrics` as `dynamicGI`.

The corridor uses 1485 probes × 128 rays: 4.35 MiB of immutable surface data,
shared between day/night, plus about 0.204 MiB of SH history per view. The
default update performs at most 64×9×128 ray contributions per frame, with up
to four current lights, and a small full-SH-atlas copy/update pass. Dynamic
sampling adds grid interpolation to lightmapped surfaces; performance must be
measured on target hardware, not inferred from probe count.

## Limits

Only one dynamic diffuse bounce is calculated. This is relighting of cached
static geometry, not a complete DDGI/RTGI or Lumen implementation. Geometry,
material or placement changes require rebuilding the surface paths; static
day/night sky and sun remain the baked base solution. Moving occluders affect
the source-to-bounce shadow segment, but probe-to-bounce connections and probe
visibility remain static. Opening a door does not retrace those connections.

Finite directional sampling can miss a narrow spotlight footprint; 256 rays
improve angular coverage at additional cost. Albedo is sampled at triangle
centres, indirect maps are non-directional/low-frequency, and shadow visibility
has the existing atlas resolution/bias limits. A 12 mm surface offset reduces
self-shadowing. Source outgoing radiance is capped at 32 before SH projection
to keep singular near-light highlights bounded. Alpha-masked/translucent and
specular transport are excluded. Cached positions use half-float world units.

Windows RTX/WebGPU pixel tests cover a point light completely behind the
camera, movement, immediate off clearing, a turned hidden spotlight and an
off-screen shadow blocker. Static lightmaps also receive the new light, and
the off path removes history/statistics. A regression test covers Windows
CRLF shader stage parsing. Native corridor captures and exact build/content
hashes are recorded separately in Last Autumn's `Evidence/DynamicGI`.
Apple hardware validation remains open; the earlier full golden-suite baseline
exception remains separate and no old references were re-recorded.
