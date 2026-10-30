# ADR-0027: 3D rendering pipeline gap analysis and roadmap

- Status: Accepted
- Date: 2026-10-16
- Implementation: Partial; native DLSS, the photorealism foundation, baked GI and dynamic local-light probe relighting implemented locally. Adaptive/retraced geometry GI, RT and virtualized geometry/shadows remain.

## Photorealism work, 2026-10-30

This audit supersedes the absence claims in the original 2026-10-16 context
below. It is the implementation contract for the Last Autumn rendering work.
The user requested that the remaining gaps be recorded here and that the main
practical subset be implemented. Existing cascaded shadows are retained.

| Feature | Starting state on 2026-10-30 | Delivery / acceptance |
| --- | --- | --- |
| Windows DLSS / DLAA | Implemented through native WebGPU/Dawn + NGX; real GPU and game acceptance | Keep working; see [DLSS](../DLSS.md). This is not an absent feature. |
| Portable TAA / temporal upscaling | MetalFX on Apple, DLSS on supported Windows adapters; no vendor-independent temporal reconstruction | Add motion/depth history, rejection and neighborhood clipping on the existing graph; verify native fallback and DLSS selection remain distinct. |
| SSGI | Absent; static IBL/captures only | Bounded diffuse screen-space ray tracing with real receiver albedo, depth/normal rejection, HDR composition and an off path with no pass/target cost. Verify moving-light color transfer and occlusion with GPU pixels. Screen/off-screen limitations must remain explicit. |
| Surface lightmaps | No complete system; corridor has static AO/visibility only | Add linear HDR diffuse-lightmap assets, UV1 sampling and a reproducible offline bake/import path. Verify per-texel lighting and no duplicate direct illumination. First delivery may be non-directional. |
| Spatial irradiance probes | One capture per test scene, no spatial visibility | Add a bounded spatial grid, interpolation and visibility/leak controls, with a reproducible bake. A regular grid is not a complete Adaptive Probe Volumes or DDGI implementation. |
| PCSS | Directional PCF only | Add blocker search and receiver/blocker-dependent penumbra, cascade-safe bounds and a compatibility PCF default. Verify penumbra changes with blocker separation. |
| Contact shadows | SSAO only; no per-light visibility supplement | Add bounded screen-space rays toward actual light sources. Affect their direct light only; preserve emissive, baked/indirect light and sky. Verify source direction and an occluding fixture. |
| Local volumetric lighting / fog | Half-resolution primary-sun shafts in global height fog | Add bounded local density volumes and point/spot scattering using the real local-shadow atlas. Verify a moved flashlight, a blocked cone and volume exit. |
| Hardware RTGI / RT shadows | Absent | Remaining major work under ADR-0021: acceleration structures, native interop, hit shading, denoising and temporal validation. SSGI must not be described as RTGI. |
| Virtual Shadow Maps | Absent; ordinary cached local maps and cascades exist | Remaining work: virtual page allocation, feedback, residency, invalidation and GPU-driven shadow rendering. PCSS does not close this item. |
| Nanite / Lumen equivalents | Absent | Separate large systems, not the scope of this practical delivery. Do not use their names for the smaller implementations above. |

Implementation order: diffuse transport (SSGI and baked spatial lighting),
shadow quality/contact, local volumetrics, portable temporal reconstruction.
Use existing render targets, settings, extraction and shader variants; defaults
must preserve existing scenes. New limits and unsupported-device behavior must
be visible in API/docs, not simulated by nonfunctional toggles.

Acceptance is actual GPU output plus deterministic state/serialization checks,
then the release game in the corridor and combat labs. Record input/output
resolution, selected reconstruction, real encoded/fallback counts, GPU errors,
and before/after images. Performance acceptance is separate: CPU frame cadence
is not GPU time, generated frames are not simulation FPS, and the 140/144+ FPS
target is not accepted without a controlled measurement. Keep a dated factual
completion table here; planned items are not completed by merely adding fields.

### Delivery recorded on 2026-10-30

| Item | Actual delivery | Remaining limits |
| --- | --- | --- |
| DLSS / DLAA | Native WebGPU/Dawn + NGX retained; distinct from explicit portable TAA | Windows RTX only; no frame generation or ray reconstruction |
| Portable TAA / TAAU | HDR color/depth history, motion reprojection, disocclusion rejection, YCoCg clipping, reactive mask, per-camera resets | Basic reconstruction; scene-specific ghosting/fine-detail review remains |
| SSGI | One-bounce screen-space diffuse rays, receiver BRDF/albedo attachment, bilateral reconstruction and HDR composition | Visible opaque surfaces only; no hidden/off-screen transport or separate temporal GI denoiser; bloom/exposure metering still reads the earlier scene buffer |
| PCSS | Directional blocker search and physical separation-dependent bounded penumbra, isolated cascade footprints | Local lights retain PCF; conventional shadow maps remain |
| Contact shadows | Camera-depth prepass and per-source screen-space direct-light visibility | Primary sun and up to four shadow-atlas lights; screen-space/foveation limits |
| Local volumetric fog | Eight additive density boxes, soft edges, colored scattering, bounded point/spot lighting and real local-shadow atlas | Single scattering and finite ray march; not a froxel system |
| Surface lightmaps | Implemented: padded secondary-UV atlas in derived GLBs, linear HDR sidecars, per-material import, offline diffuse transport, mixed-lighting policy and GPU pixels | Non-directional; static opaque transport with triangle-centre source-radiance approximation; rebake after static changes |
| Spatial irradiance probes | Implemented: regular L2 RGB SH grid, visibility, bake/import and optional GPU relighting of static surface paths by moving local lights | Fixed geometry paths; no adaptive APV, runtime relocation/retracing or complete DDGI |
| RTGI / RT shadows, VSM, Nanite / Lumen equivalents | **Open** | Separate major systems; practical screen-space additions do not close them |

The five practical additions default off (PCF remains the shadow default).
Last Autumn supplies an opt-in `--render-foundation` preset and separate
DLSS/portable-TAA launchers. This closes the first practical implementation
slice, not the full roadmap. API, memory costs and algorithm limits are in
[RenderingFoundation](../RenderingFoundation.md); reproducible native game
reports and pixel captures are in Last Autumn's `Evidence/RenderingFoundation`.

Validation includes direct-radiance color transfer and removal, per-source
contact shadow pixels, PCSS blocker-distance penumbra growth, local fog with
zero global density, a turned spotlight and shadow-atlas occlusion, and portable
temporal history after motion, resize and cuts. The established sun-only fog
shader remains a separate compatibility path. The full validation runs 261
tests with 22 golden-image issues across 13 tests. A control run with HEAD's
flat, reflection, directional-shadow and volumetric shaders in the task-local
validation bundle reproduces all 22 issues (21 actual images pixel-identical;
the auto-exposure capture varies with its frame timing). References have not
been re-recorded. This is an unresolved existing rendering/reference baseline,
not a green full-suite acceptance. See the evidence report for the focused
feature checks and native game runs.

### Baked diffuse GI delivery, 2026-10-30

The base GI path now combines static surface lightmaps, spatial lighting for
moving receivers, and the earlier screen-space dynamic bounce. The offline CPU
BVH integrates sky visibility and static diffuse interreflection. Receiver maps
store incident diffuse irradiance divided by pi; runtime analytic direct sun,
point and spot lighting is excluded. The PBR shader replaces diffuse ambient,
retains specular IBL, and avoids applying material AO twice to baked diffuse.
The old procedural ambient fill is suppressed in baked views without IBL.
Static diffuse now participates in the main HDR buffer, exposure metering and
bloom. Existing SSGI subtracts that indirect buffer before tracing another bounce.

The corridor has two fixed bakes (clear 12:00 and 00:00), each with 39 lightmaps,
1485 probes (1312 valid), 16x16 octahedral visibility per probe, and 13.87 MiB of
HDR texture data. Derived GLBs retain original UV0/PBR data; UV1 charts and any
old UV1 AO are remapped into independent charts. Day/night geometry and charts
are identical. Imported shared materials remain untouched; model instances own
their bindings. Asynchronous model arrivals are reconciled with the selected
lighting state. Baking/source/tool/output hashes are verified before packaging.

Acceptance: four offline transport/visibility/UV/fingerprint tests, three
game-side asset/fingerprint/relocation tests and 26 actual WebGPU/renderer-history
checks pass, including loading the real derived model,
sidecars and probe grid. Native day/night, state-change and reconstruction runs
are recorded separately in Last Autumn's `Evidence/BakedGI`. No old golden
reference has been re-recorded and the earlier full-suite baseline exception
above remains distinct from this focused acceptance. See [BakedGI](../BakedGI.md)
for formats, commands, cost and remaining approximation limits.

### Dynamic local-light probe relighting, 2026-10-30

Optional `.proberays` assets cache static world-space surface hits from each
probe. A bounded pass after local shadows relights those hits from current
point/spot sources, projects SH9, and updates per-view ping-pong histories.
Source selection includes the cached surfaces' bounds independently of camera
visibility. Real light-volume shadows occlude injection; unavailable shadow
slots fail closed. Dynamic diffuse adds to lightmaps and spatial receivers
before exposure/bloom. Old lights opt out with `indirectIntensity = 0`, so
authored static bounces are not counted twice. The game preset disables SSGI
to avoid duplicate first-bounce local lighting.

The corridor reuses 1485 probes with 128 paths/probe (4.35 MiB static data),
64 updates/frame and 15% history retention on refresh. One full sweep takes at
most 24 rendered frames. No-source frames clear the whole field immediately.
This closes moving-light off-screen first diffuse bounce for static geometry;
it does not close runtime geometry/visibility retracing, adaptive probes,
multi-bounce dynamic GI, hardware RTGI or transparent/specular transport.

33 focused renderer/history/cache checks pass, including actual WebGPU pixels
for a point light entirely behind the camera, lamp movement, a turned hidden
spotlight, an off-screen shadow blocker, static-map receivers and immediate
off clearing. Two game-side transport/provenance tests also pass. A Windows
CRLF shader-parser regression was fixed and tested while integrating the pass.
Full details and costs are in [DynamicGI](../DynamicGI.md); native package
evidence is in Last Autumn's `Evidence/DynamicGI`. The prior golden-suite
baseline exception remains open.

## Context (original audit, 2026-10-16)

ADR-0017 through ADR-0021 and ADR-0025 define the current 3D direction. This
ADR records what the 3D pipeline still lacks after a source audit, groups the
gaps into independently shippable stages, and states how they relate to the
existing ADRs. It adds no behavior by itself. Where an existing ADR already
owns a gap, this ADR links to it instead of redefining it.

The audit covered `AdaCorePipelines`, `AdaRender`, the native glTF loader in
`AdaAssets`, `AdaScene/3D` and the existing tests. Absence claims below come
from source search and may miss code behind unconventional names; each stage
must re-verify its own premise before implementation starts.

### What exists today (not gaps)

- **Graph.** `Core3DPlugin` builds a fixed forward graph: directional shadow,
  local shadow, `Main3D` (PBR), SSAO, SSR, anti-aliasing, temporal resolve with
  tone mapping, optional `Scene2D`, upscale. There is no depth/normal prepass
  and no deferred path; SSAO and SSR consume depth and normals produced
  after the main pass.
- **Lighting.** Metallic-roughness PBR; up to 4 directional and 32 local lights
  per frame, with 4 shadow-casting lights and a per-camera shadow atlas budget
  (ADR-0018); cascaded directional shadows; baked IBL and a procedural or
  textured skybox with starfield; SSR.
- **Tone mapping.** A fixed ACES-fit curve followed by the sRGB transfer inside
  the temporal resolve shader. There is no exposure input.
- **Batching.** Opaque meshes are batched by mesh/material/skin key and drawn
  with per-instance data and `instanceCount`. Blended meshes are not merged and
  are depth sorted in `Main3DRenderNode`.
- **Visibility.** CPU frustum, distance and LOD culling; Metal and WebGPU GPU Hi-Z
  occlusion with indirect draw (ADR-0020).
- **Skinning and animation.** GPU skinning, skeletal animation graphs, animation
  LOD, motion vectors for camera, rigid and skinned meshes (ADR-0017).
- **Assets.** Native glTF import with PBR metallic-roughness, `KHR_mesh_quantization`
  and `KHR_materials_emissive_strength`; voxel import and meshing (ADR-0025).
- **Backends.** Metal is the reference backend; native WebGPU is validated for
  lighting and shadows (ADR-0018). Vulkan and OpenGL backends exist.

### Gaps

Gaps already owned by another ADR are marked with their owner.

**G1. Post-processing is not a stack.** No exposure, bloom, depth of field,
motion blur, color grading or vignette. The only post chain is hard-wired
graph nodes. Owner for exposure and bloom: ADR-0019.

**G2. Materials are the base glTF PBR set only.** `PBRMaterial` has no
clearcoat, transmission, volume, IOR, specular, sheen, anisotropy or UV
transform. The loader accepts exactly two extensions and rejects others it
does not know. `KHR_lights_punctual` is not imported.

**G3. No morph targets.** Neither the importer nor the runtime has blend
shapes. This blocks facial animation, corrective shapes and many character
assets.

**G4. Transparency is sort-only.** Blended meshes are depth sorted per object.
Intersecting or large transparent meshes produce ordering artifacts. There is
no order-independent transparency and no transmission or refraction pass for
PBR.

**G5. No atmosphere or volumetrics.** No distance or height fog, no physical
sky, clouds, volumetric fog or light shafts. Reflections of the sky outside SSR
range depend only on baked IBL. Planar reflections are absent.

**G6. Lighting scale and quality.** Lights are evaluated by a flat loop over
the per-frame light list (not clustered or tiled). Missing: contact shadows,
soft penumbra shadows, area lights, light cookies/IES profiles. Probes,
lightmaps and unified reflection composition are owned by ADR-0019; ray traced
reflections by ADR-0021. There is no dynamic GI.

**G7. Scene content features.** No decals, terrain, water, foliage/wind or
GPU particles in 3D. Static meshes have no automatic LOD generation; ADR-0020
LOD covers skinned meshes and animation cadence. Hi-Z occlusion and indirect
draw exist only on Metal (ADR-0020 notes this as a backend extension).

**G8. Renderer introspection and regression safety.** The command encoder has a
wireframe fill mode, but there are no 3D debug views (normals, depth, overdraw,
shadow cascades, light heat map), no runtime GPU timing overlay, and no
user-facing 3D debug-draw API. Existing 3D tests exercise extraction,
scheduling, history and budgets in code; none compares rendered frames to
reference images, so visual regressions rely on manual captures recorded in
ADRs.

**G9. Platform parity.** TAA/MetalFX proof on Apple mobile and non-Metal
fallbacks is unrecorded (ADR-0017). Several passes (Hi-Z, indirect draw, SSR,
SSAO) are only proven on Metal.

## Decision

Close the gaps in the stages below. Each stage ships behind its own
checklist item with recorded validation, and stages may be reordered when a
dependency is satisfied. Prefer extending the existing render graph, ECS
extraction and `Environment3D`/camera settings over parallel systems. Keep
scene color linear HDR until the final output transform. UI stays outside 3D
post-processing and exposure.

### Stage 0. Foundations

These unblock later stages and make their results verifiable.

1. **Debug views and diagnostics.** Add per-camera debug view modes: wireframe,
   normals, depth, albedo/roughness/metallic, overdraw, shadow cascade tint and
   light-count heat map. They are developer features, off by default, and add
   no cost to the normal path. Expose GPU pass timings next to the existing
   `Render3DPerformanceMetrics`. Add a small 3D debug-draw API (lines, boxes,
   spheres, frusta, axes) with a lifetime in frames. The first slice covers the
   views that read data the main pass already writes; views that need new
   shader outputs (albedo, overdraw, cascade tint, light heat map) follow.
2. **Golden-frame tests.** Add a headless render-and-compare harness for
   deterministic scenes (PBR spheres, shadows, skybox, transparency). Compare
   against stored references with a documented tolerance per backend. Native
   Metal is the reference; other backends record their own tolerances.
3. **Shared depth/normal prepass.** Decide with measurement whether a prepass
   improves SSAO, SSR, decals and contact shadows enough to justify its cost. If
   adopted, expose depth and normals as render-graph resources so later effects
   do not each re-render geometry. If rejected, record the measured reason.

### Stage 1. Post-processing stack

ADR-0019 owns manual exposure and HDR bloom. This stage generalizes that work.

- Introduce per-camera post-process settings (a component or `Environment3D`
  extension) with ordered, individually toggled effects and a defined order:
  exposure/auto-exposure, bloom, depth of field, motion blur, color grading,
  tone mapping, vignette/grain, then anti-aliasing/upscale as already ordered by
  ADR-0017.
- Make tone mapping an operator choice (at minimum the current ACES fit, a
  neutral operator and none) with exposure applied before it. The default must
  reproduce current output for existing scenes.
- Add auto-exposure (histogram or average-luminance, with adaptation speed and
  min/max EV) after manual exposure is stable.
- Add depth of field and per-object/camera motion blur using the existing
  motion vectors; both are bounded by quality settings and disabled on devices
  that cannot afford them.
- Add 3D LUT color grading with an asset type and Editor preview.
- Reuse downsample/upsample targets across effects through render-graph
  resources; effects that are off allocate nothing.

### Stage 2. Materials and glTF import

- Extend `PBRMaterial` additively with optional extension blocks so existing
  materials, scene payloads and shaders decode and render identically. Order of
  implementation by value: `KHR_texture_transform`, `KHR_materials_ior`,
  `KHR_materials_specular`, `KHR_materials_clearcoat`,
  `KHR_materials_transmission` and `KHR_materials_volume` (see Stage 4),
  `KHR_materials_sheen`, `KHR_materials_anisotropy`. Import
  `KHR_lights_punctual` into the existing light components.
- The loader keeps rejecting extensions marked `extensionsRequired` that it
  does not support. Extensions listed only in `extensionsUsed` and not
  supported must degrade to the base material and report a warning, not fail.
  Maintain the supported list in one place and document it.
- Material variants must not multiply pipeline permutations unboundedly: add
  features through uniform data and bounded shader keys, and measure shader
  compile count and pipeline cache size.
- Add an Editor inspector for the new fields and update the
  `ada-3d-materials` agent skill.

### Stage 3. Morph targets

- Define a morph-target asset: per-primitive position/normal/tangent deltas,
  default weights, and target names. Import from glTF `targets` and `weights`,
  including animated `weights` channels.
- Evaluate on the GPU with sparse or compacted deltas and a hard limit on
  active targets per mesh (for example 8), selecting the highest weights. Combine
  correctly with GPU skinning (morph first, then skin).
- Keep motion vectors, shadow pass geometry and bounds correct for morphed and
  morphed-plus-skinned meshes; conservative bounds must cover the maximum
  displacement.
- Integrate with keyframe animation and the animation graph as animatable
  weights, and expose weights to AdaScript and the Editor.

### Stage 4. Transparency

- Add order-independent transparency as an opt-in camera/material mode for
  blended PBR, choosing between weighted blended OIT (cheap, approximate) and a
  per-pixel list technique after measuring on Metal and WebGPU. Keep the
  existing sorted path as the default and fallback.
- Add a transmission pass: render opaque scene color to a mip-chained
  texture, sample it through roughness-dependent blur and IOR-driven offset for
  `KHR_materials_transmission`/`volume` materials. Transmissive surfaces do not
  see other transmissive surfaces in the first version; document that limit.
- Define how shadows are cast by blended materials (alpha-masked casting
  already exists per ADR-0018) and how SSR/SSAO treat them.
- Clarify the relationship with the existing `GlassRenderPipeline`, which
  renders screen-space glass quads: it is not PBR transmission, and neither
  replaces the other without a separate decision.

### Stage 5. Atmosphere, fog and volumetrics

- Add distance and height fog to `Environment3D`, applied in linear HDR before
  tone mapping, with color, density, falloff and optional sun in-scattering.
- Add a physically based sky (precomputed transmittance and multi-scattering
  LUTs, driven by the primary directional light) as an alternative to the
  gradient/texture skybox, plus a time-of-day driver. Sky must feed IBL so
  ambient lighting follows it; define a bounded update cost.
- Add froxel volumetric fog and light shafts for directional and shadowed local
  lights, opt-in and quality-scaled. Cloud rendering is a separate follow-up.
- Add planar reflections for water and mirrors with a bounded extra-render cost
  and clear integration with the ADR-0019 reflection composition contract.

### Stage 6. Lighting scale and quality

- Replace the flat per-frame light loop with clustered (or tiled) forward light
  assignment once lights routinely exceed the current loop's budget, measured
  against the 32-light limit. Raise limits only with evidence.
- Add screen-space contact shadows for small-scale detail and percentage-closer
  soft shadows with light-size-driven penumbra for directional and spot lights.
- Add rectangular/tube area lights (LTC) and light cookies/IES profiles for spot
  and directional lights.
- Probes, baked indirect lighting and reflection composition stay in ADR-0019;
  ray tracing stays in ADR-0021. Dynamic GI (SSGI or probe grids) is deferred
  until probes ship and a scene needs it. Virtual shadow maps are deferred
  until cascades demonstrably fail on target scenes.

### Stage 7. Scene content features

Each item needs its own short requirements note before implementation.

- **Decals.** Projected box decals with albedo, normal and roughness, depth
  and normal aware, clustered with lights if Stage 6 lands.
- **Instancing and LOD.** Static-mesh LOD generation and selection in the import
  pipeline, using the ADR-0020 visibility contract. Extend instancing to
  blended meshes only if Stage 4 makes this meaningful. Meshlets/mesh shaders
  are explicitly deferred.
- **Terrain and water.** Heightmap terrain with tiled LOD and splat materials;
  water surface with reflection, refraction and depth fade, built on Stages 4
  and 5.
- **Foliage.** Instanced vegetation with wind animation, distance fade and
  alpha-to-coverage.
- **3D particles.** GPU particles with lit and unlit modes, soft depth fade,
  and depth sorting that cooperates with Stage 4. Particles need their own
  requirements, as ADR-0022 already states for 2D.
- **Backend parity.** Hi-Z occlusion and indirect draw are implemented on Metal
  and WebGPU (ADR-0020); browser runtime validation remains separate from native
  GPU validation. Implement the Vulkan path, or document a measured CPU fallback
  as the permanent contract.

### Stage 8. Platform parity and budgets

- Record the TAA/MetalFX Apple mobile and non-Metal results required by
  ADR-0017.
- For every new effect, define a quality tier, a backend capability check, a
  safe fallback and a GPU/memory budget. An unsupported device must degrade
  visibly to the previous behavior, not fail.
- Keep WebGPU pixel validation (`script/validate_webgpu.sh`) in the checklist
  for any shader change that must run on the web.

## Non-goals

- A deferred or visibility-buffer renderer. Revisit only if clustered forward
  proves insufficient with measurements.
- Replacing the render graph or the Metal-first backend strategy.
- Dynamic global illumination, ray traced GI/shadows and virtual geometry. The
  first remains deferred (ADR-0019); ray tracing is ADR-0021.
- Expanding the glTF extension set beyond those listed in Stage 2 without a
  real asset needing it.

## Priority order

1. Stage 0 (diagnostics and golden frames), so everything after it is verifiable.
2. Stage 1 exposure and bloom (ADR-0019), then the rest of the post stack.
3. Stage 3 morph targets and Stage 2 material extensions (asset correctness).
4. Stage 5 fog and sky, then Stage 4 transparency.
5. Stage 6 clustered lights and shadow quality, then Stage 7 content features.
6. ADR-0019 probes and ADR-0021 ray tracing as already ordered by their ADRs.
7. Stage 8 runs continuously alongside each stage.

## Implementation checklist

- [x] Stage 0: debug views from existing main-pass outputs (normals, depth, roughness, metallic, SSAO, indirect light, wireframe).
- [x] Stage 0: albedo, cascade tint and light-count debug views (the main pass colors scene color by selector).
- [ ] Stage 0: overdraw debug view (needs a counting pass; see the second-pass notes).
- [x] Stage 0: GPU pass timing (already provided by `Render3DPerformanceMetrics`; the debug passes record into it).
- [x] Stage 0: GPU timing report table (`Render3DPerformanceMetrics.report()`).
- [ ] Stage 0: on-screen GPU timing overlay (needs a UI host in the app or Editor).
- [x] Stage 0: Editor controls for the debug view and the post-processing settings.
- [x] Stage 0: 3D debug-draw API (lines, polylines, boxes, AABBs, spheres, axes, frusta; depth-tested or overlay).
- [x] Stage 0: golden-frame harness with Metal tolerance and checked-in references.
- [x] Stage 0: golden-frame references and tolerance for WebGPU, plus a Metal/WebGPU agreement test.
- [ ] Stage 0: golden-frame references for other backends (Vulkan, OpenGL, Windows).
- [x] Stage 0: GPU/CPU performance baseline harness (`Render3DGPUTests/Benchmarks`) with reproducible numbers.
- [x] Performance pass 1: visible-list preparation, SSR trace cost and redundant shadow lookups (numbers below).
- [ ] Stage 0: prepass decision confirmed with GPU measurements (the harness now exists; overdraw is still not measured).
- [x] Stage 1: per-camera `PostProcess3D` with manual exposure (ADR-0019 exposure).
- [x] Stage 1: HDR bloom with reusable per-camera chain (ADR-0019 bloom).
- [x] Stage 1: tone-map operator choice (ACES fit, neutral, none) and a shared output-transform shader.
- [x] Stage 1: auto-exposure, saturation/contrast, strip-LUT color grading and vignette.
- [x] Stage 1: depth of field.
- [ ] Stage 1: motion blur (needs a velocity buffer that exists without temporal upscaling).
- [ ] Stage 1: quality tiers for depth of field, bloom and auto-exposure.
- [x] Stage 2: `KHR_texture_transform`, `KHR_materials_ior` and `KHR_materials_specular` factors (see "Stage 2, first slice").
- [x] Stage 2: `KHR_materials_clearcoat` factors (see "Stage 2, second slice").
- [x] Stage 2: parallax occlusion mapping from `PBRMaterial.heightTexture` (world-unit `heightScale`, per-pixel ray march in `flat3d.glsl` that derives the UV shift from screen-space derivatives so no tangents are needed; the height map is read with the base color sampler because Metal has no free sampler slot; depth, shadows and silhouettes are not displaced; no glTF import yet because no displacement extension is ratified).
- [x] Stage 2: sheen and anisotropy factors (see "Stage 2, third slice").
- [x] Stage 2: clearcoat, clearcoat roughness and normal, sheen color and roughness, anisotropy and specular textures (see "Stage 2, fifth slice").
- [ ] Stage 2: `KHR_lights_punctual` import.
- [x] Stage 2: unsupported-extension degradation policy and documented supported list (`NativeGLTFLoader.supportedExtensions`, `GLTFImportResult.warnings`).
- [x] Stage 3: morph-target asset, glTF import and GPU evaluation (see "Stage 3, first slice").
- [x] Stage 3: morph with skinning, shadows, motion vectors and bounds.
- [x] Stage 3: animated weights (clips, crossfades and the animation graph) and AdaScript access (see "Stage 3, second slice").
- [x] Stage 3: Editor panel for morph weights (see "Stage 3, third slice").
- [ ] Stage 4: OIT mode with sorted fallback.
- [ ] Stage 4: transmission/volume pass.
- [x] Stage 5: distance/height fog (`Fog3D` in `Environment3D`, applied in the composite pass; see "Stage 5, first slice").
- [ ] Stage 5: physically based sky feeding IBL and time-of-day driver.
- [x] Stage 5: sun light shafts through the fog (half-resolution raymarch, `Fog3D.volumetric`; see "Stage 5, second slice").
- [ ] Stage 5: froxel volumetric fog for local lights, fog volumes and planar reflections.
- [x] Stage 6: tiled local-light assignment with measured limits (2D tiles, CPU masks; depth slicing is not done; see "Stage 6, first slice").
- [x] Stage 6: reuse of unchanged local shadow faces (see "Stage 6, second slice").
- [ ] Stage 6: contact shadows, soft shadows, area lights and cookies.
- [ ] Stage 7: decals, static-mesh LOD, terrain, water, foliage, 3D particles (each with its own requirements note).
- [ ] Stage 7: Hi-Z/indirect-draw parity on WebGPU and Vulkan or documented fallback.
- [ ] Stage 8: Apple mobile and non-Metal proof for TAA and the new effects.

## Recorded implementation

### Stage 0, first slice (2026-10-16)

**Debug views.** `DebugView3D` is selected per camera through
`Environment3D.debugView` (default `.none`; absent in older scene payloads
decodes to `.none`). `.normals`, `.depth`, `.roughness`, `.metallic`,
`.ambientOcclusion` and `.indirectLighting` run one fullscreen
`DebugView3DRenderNode` after the last color writer (SSR composite, FXAA or
temporal resolve) and before debug draw and 2D/UI, so debug output is not
anti-aliased, tone mapped or upscaled. It samples the normal/roughness and
view-position/metallic targets the main pass already writes, the SSAO result and
the indirect-light target; a camera on `.none` or `.wireframe` records no GPU
work in that node. `.wireframe` switches the main pass to line fill through the
existing `setTriangleFillMode`; the WebGPU encoder implements that call as a
no-op, so wireframe renders solid there. Early passes that notify the output as
presentable (`SSR`, `FXAA`) defer that notification when a debug view or debug
lines will still draw.

```swift
camera.environment.debugView = .normals   // or .wireframe, .depth, ...
```

**Debug draw.** `DebugDraw3D` is a main-world resource registered by
`Core3DPlugin`. Shapes live for `duration` rendered frames (default 1, values
below 1 draw once), are extracted once per render frame, and are bounded by
`maximumLineCount` with `droppedLineCount` for overflow. Non-finite input is
rejected. Rendering reuses `LinePipeline` with two variants: `lessOrEqual`
against the scene depth (the upscaled output depth when temporal upscaling is
active) and `always` for overlay lines.

```swift
let draw = world.getResource(DebugDraw3D.self)!
draw.box(transform: entityTransform, halfExtents: [0.5, 1, 0.5], color: .green)
draw.sphere(center: target, radius: 2, color: .yellow, duration: 60)
draw.line(from: origin, to: hit, color: .red, depthTested: false)
```

**Golden frames.** `GoldenFrame` (Tests/AdaEngineTests/GoldenFrameSupport.swift)
compares a rendered image with `GoldenFrames/<backend>/<name>.png` using a
per-channel step and a differing-pixel fraction (Metal: 2 steps, 0.05% of
pixels). `ADAENGINE_GOLDEN_RECORD=1` rewrites references; a mismatch writes the
actual and a difference image to `ADAENGINE_GOLDEN_OUTPUT`. The Metal suite
renders four PBR spheres (roughness 0.1-0.9, metallic 0-1) with a shadowed sun
and checks each debug view, debug draw and the return to the normal frame.

### Stage 1, first slice: exposure and bloom (2026-10-16)

**Settings.** `Environment3D.postProcess` holds `PostProcess3D`: `exposureEV`
(stops; `0` is unchanged, limited to ±10 so half-float targets cannot overflow)
and `Bloom3D` (`isEnabled` false by default, `intensity`, `threshold` in
exposed linear units, `softKnee`, `scatter`). Missing keys decode to defaults, so
older scenes are unchanged, and non-finite values are replaced before reaching
the shader. Flat accessors (`exposureEV`, `bloomEnabled`, `bloomIntensity`,
`bloomThreshold`) serve scripts and inspectors.

```swift
camera.environment.exposureEV = -1
camera.environment.postProcess.bloom = Bloom3D(isEnabled: true, intensity: 0.4, threshold: 1)
```

**Where it runs.** Tone mapping lives in two shaders: the environment
composite (direct and FXAA presentation) and the temporal tone map. Both
consume the composite's output, so exposure and bloom are applied once inside
`presentColor` in the composite, before tone mapping, instead of in two places:
`color * exposure + bloom * intensity`. With temporal upscaling the composite
writes HDR, so the upscaler sees pre-exposed input. `Bloom3DRenderNode` runs
between SSAO and the composite. It prefilters the lit scene color at half
resolution (exposure, soft knee, per-tap clamp), downsamples with a dual filter
to at most six levels, then adds each wider level back with additive blending
and a `scatter` weight. A disabled or zero-intensity bloom records no GPU work and
releases its textures; the composite then multiplies a white placeholder by zero,
so default frames are bit-identical to before.

**Tone mapper.** `PostProcess3D.toneMapper` selects `ToneMapper3D`: `.aces`
(default, the previous Narkowicz fit), `.neutral` (Khronos PBR Neutral, which
keeps authored colors nearly untouched until highlights compress) or `.none`
(clip). The sRGB encode and all three curves now live once in the engine's public
`Tonemapping.glsl` (`#include <AdaEngine/Tonemapping.glsl>`) and are included by
both tone-mapping shaders, the environment composite and the temporal tone map,
which previously each carried a copy of ACES. The selector is `u_PostProcess.z`
in the composite and a new trailing member of `Temporal3DUniform` in the temporal
pass; shaders that do not declare it ignore the extra bytes. `.aces` is selector
`0` and old payloads omit the key, so existing scenes and every earlier golden
frame are unchanged. An unknown tone-mapper name fails to decode rather than
silently falling back. The temporal pass reads the environment as an optional
resource, so a world without environments keeps ACES.

```swift
camera.environment.toneMapper = .neutral
```

**Known limits.** Bloom is built from lit geometry, so a bright skybox pixel
adds no energy (geometry bloom still spreads over it). Intense sources produce a
wide faint veil from the widest levels; lower `scatter` narrows it. There is no
temporal stabilization of the bloom chain, and upscaler input is pre-exposed
rather than described through the scaler's exposure parameter.

**Validation.** Metal, macOS, Swift 6.2.3. All existing golden frames still
match at default settings. New tests cover: glow beside an emitter that fades
with distance and leaves low-energy pixels almost untouched; monotonic
intensity; identical frames for disabled and zero-intensity bloom; exposure
brightening and darkening; chain allocation and release; and bloom plus
exposure on all three presentation paths (direct, FXAA, temporal upscaling at
render scale 1 with the upscale plugin). Four new golden frames
(`emissive-*`) cover bloom and exposure, and two more cover the neutral and
clipped tone mappers; a test renders every operator through the composite and
through the temporal shader and requires the pictures to agree within 4 steps,
which guards the shared include. Other checks: ACES output equals the default
frame, an overbright emitter reads as near white under every operator, and
neutral stays closer to the uncurved image than ACES at mid-tones. Not verified in this slice: other platforms,
MetalFX-specific behavior beyond the offscreen temporal path, the Editor, and
non-default render scales for the temporal path.

**Unexplained transient.** Two consecutive Metal runs, the first after building
this slice, failed with a whole-frame shift of about 5 steps and 245 pixels
differing between two renders of one scene. The identical binary then passed in
every later run (warm and cold shader cache, under heavy CPU load, after a
shader edit; about ten runs). The cause was not found. A real stale-shader
cache bug was found later (second pass below, fixed); it is plausible but
unproven that it explains this. The golden tolerance would flag the drift again.

**Findings during implementation.**

- `DepthStencilDescriptor.isDepthTestEnabled` is not read by any backend; depth
  testing is governed by `depthCompareOperator` alone. Use `.always` to disable
  testing. This is existing behavior and not changed here.
- The main pass already writes view-space normals, roughness, view position and
  metallic to dedicated targets, so SSAO, SSR and the debug views need no
  depth/normal prepass.
- `Render3DPerformanceMetrics` already measures per-pass GPU time with warmup;
  the new passes record as `debug` and `debugDraw`.

**Prepass decision (analysis, not measurement).** No separate prepass is
adopted now. Current consumers (SSAO, SSR, debug views) read the main pass
outputs, and ADR-0020's Hi-Z occlusion has its own previous-frame and
disocclusion handling, so no existing consumer needs depth or normals before
the main pass. A prepass would add a second geometry
submission (including skinned, instanced and alpha-masked items) for an
early-Z saving nobody has measured. Revisit when a stage needs pre-main-pass
depth (for example clustered light bounds or decal culling) or when measured
overdraw in a target scene is high. The measurement stays an open checklist item.

**Validation.** On macOS with Swift 6.2.3: the full engine suite passed (1756
tests, GPU suites gated by environment variables). The Metal suite
(`ADAENGINE_GOLDEN_METAL=1 swift test --filter Render3DDebugViewMetalTests`)
passed 5 tests, and a deliberate depth-scale change was caught by exactly the
depth frame (165,082 differing pixels). WebGPU is covered in the second pass. Not
verified: Apple mobile, Windows, the windowed presentation
notification path (only offscreen targets were exercised). Editor coverage is in
the second pass. The Editor serializes `Environment3D` payloads, which now
include `debugView`; older payloads decode to `.none` (covered by an engine test).

### Performance pass 1 (2026-10-17)

**Method.** `Render3DGPUTests/Benchmarks` renders a heavy scene (400 PBR spheres
with 8 materials, a ground, a sun with three cascades, six point and two spot
lights, 1920 by 1080) under a set of configurations and reports, per
configuration, GPU milliseconds per pass (passes serialized so each is isolated),
their sum, the wall time of that serialized run, and `free`: time per frame with
nothing serialized, which is the rate the engine really sustains. Each
configuration is measured in several rounds and every figure keeps its best
round, because GPU clocks ramp and other GPU work on the machine (another test
run, Xcode) inflates single runs, for example a bare frame once read 5 ms of
geometry instead of 1.7. Run it on a quiet machine:

```sh
ADAENGINE_PERF=1 ADAENGINE_GOLDEN_METAL=1 swift test -c release -Xswiftc -enable-testing \
  --filter Render3DGPUTests/Benchmarks
```

`ADAENGINE_PERF_OUTPUT`, `_SIZE`, `_GRID`, `_FILTER`, `_ROUNDS` and `_FRAMES` select
the report file, target size, mesh grid size, configurations and effort. GPU
pass timings exist on Metal only; WebGPU reports no timestamps.

**Results on an Apple M-class GPU, 1080p, release build (best of rounds).**

| configuration | free ms/frame | notes |
| --- | ---: | --- |
| bare (geometry, shadows, composite, 8 local lights) | 2.4 | geometry 1.7, local shadows 1.15, sun shadows 0.56 |
| bare without local lights | 1.4 | local lights cost about 1 ms here |
| + SSAO | 3.3 | pass 0.66 |
| + SSR | 3.7 | composite 1.43, was 2.31 |
| + FXAA, vignette, grading, LUT | within 0.1 | effectively free |
| + bloom | 2.8 | 0.32 |
| + auto exposure | 2.8 | 0.24 (about eight tiny passes) |
| + depth of field | 3.2 | 0.75 |
| everything on | 5.7 | |
| MetalFX temporal at 75% scale | 5.1 | temporal pass 3.2 |

**What changed.**

- *Visible-list preparation.* A 4,900-mesh frame took 12 to 15 ms and was
  CPU-bound; a profile put most of the render-node time in
  `VisibleMesh3DLists.prepare`, which runs for the camera, every shadow cascade
  and every local-light face. It copied a large source value per pass and mesh,
  hashed, string-compared and dynamically cast per part, and sorted records that
  held references. It now reads fields in place, skips LOD bookkeeping for meshes
  without alternatives, builds one template per batch, keeps reference-free records
  and places them with a counting pass. A digest test
  (`VisibleMesh3DListsEquivalenceTests`) pins every draw item, instance and counter of
  the old implementation on a varied scene. One camera pass over 5,000 sources went
  from 5.24 ms to 0.57 ms, and the 4,900-mesh frame to 6.8 ms (6.2 ms without local
  lights), now bounded by the GPU. Systems still cost about half a millisecond
  per frame at that size, mostly `ExtractModel3D`.
- *Screen-space reflections.* The pass cost is almost entirely ray steps (one step
  0.31 ms, 16 steps 0.65, 48 steps 2.3 at 1080p). The trace now marches at twice the
  stride and refines the crossing with a four-step binary search, which finds the
  same hits in half the steps, and skips rays whose weight is below 0.4%. Reflections
  keep their look except for one or two pixels at the edges of reflected objects and
  smoother banding, so the reflection golden frames were deliberately re-recorded
  (`pbr-spheres-ssr*`, Metal and WebGPU). Composite: 2.31 ms to 1.43 ms.
- *Shadow lookups.* The sun and local lights sampled their shadow maps even where the
  light contributed nothing (surface facing away, outside a cone). They now skip the
  lookup when the contribution is zero; the output is unchanged.

**Where the time still goes (candidates, in order of measured cost).**

1. Local lights: about 1 ms for eight lights (13 shadow faces plus the per-pixel
   loop). Clustered or tiled assignment and a cheaper shadow filter are the options
   (Stage 6).
2. Geometry: vertex-bound for dense meshes (4,900 spheres of about 1,300 triangles
   took 4 to 5 ms regardless of resolution). Static-mesh LOD (Stage 7) is the fix.
3. MetalFX temporal at 3.2 ms is outside engine code.
4. Depth of field 0.75 ms (24 taps plus a copy pass) and SSAO 0.66 ms.
5. Many tiny passes (auto exposure, bloom) cost per-pass overhead; merging them is
   possible but showed under 0.1 ms in `free` time, so it is not worth the risk yet.

**Not measured.** WebGPU and mobile timings, memory per effect, overdraw (the
prepass decision stays open), and scenes with skinned meshes.

### Stage 0 and 1 second pass (2026-10-16)

This pass closes most open Stage 0 and Stage 1 items. Each effect keeps its
settings in `PostProcess3D`, decodes missing keys to neutral defaults, and
leaves the frame bit-identical (and allocates nothing) while it is off.

**More debug views.** `.albedo`, `.cascades` and `.lightCount`. The main pass
writes their display-ready colors into scene color when `u_ShadowAtlas.w` (a
field that was unused) selects a mode, and the debug pass shows scene color. A
new render target would not fit: the four main-pass targets already use the 32
bytes per sample that WebGPU allows. Overdraw is still open because it needs
either additive blending per material pipeline or a stencil counter, neither of
which fits the current per-item pipelines without a larger change.

**Timing report.** `Render3DPerformanceMetrics.report()` renders the measured
passes as an aligned table, slowest first, with the summed average (a budget
indicator, since passes can overlap). An on-screen overlay needs a UI host and is
left to the app or Editor.

**Auto exposure.** `AutoExposure3D` meters the log-luminance of lit pixels
covered by geometry (64 by 64 meter, 2x2 chain to one pixel), then adapts a
one-pixel exposure state in stops toward mid gray at separate up and down speeds
(`infinity` snaps). The manual `exposureEV` acts as compensation. Bloom and the
composite read the state. Pixels with no geometry or no light carry no weight and
a frame with nothing to meter holds the last value. Exposure always starts at
0 EV and adapts, rather than snapping to the first measurement: the first frames
of a scene are often only partly lit, and snapping stranded a slow adaptation at
an extreme in testing. The sky is not metered (it is added later in the
composite), so a dim scene with a bright sky can overexpose the sky.

**Vignette and color grading.** `Vignette3D`, saturation and contrast act on
linear HDR in the composite. An optional strip LUT (documented on
`ColorGrading3D`: `N` tiles of `N` by `N`, red along x, green down the rows,
blue by tile, sampled without sRGB decoding) acts on the display color after
tone mapping, in both the composite and the temporal tone-map shader, through
the shared `ColorGrading.glsl` include.

**Depth of field.** `DepthOfField3D` gathers a 24-tap bokeh disc on the final
display color after tone mapping and anti-aliasing, using the view depth the main
pass already writes; sky counts as infinitely far, and neighbors contribute only
as much as their own blur reaches, so sharp surfaces do not smear into blurred
ones. It works on display values, so very bright highlights do not become bokeh
balls. It uses a scratch texture created only while it runs. It is skipped
under a full-screen debug view. **Motion blur** is not done: motion vectors exist
only when temporal upscaling is active, so it needs a velocity buffer of its own.

**Editor.** The Environment 3D inspector has controls for the debug view,
exposure, tone mapper, auto exposure, bloom, depth of field, saturation,
contrast and vignette. The color-grading LUT asset has no inspector field yet.

**WebGPU validation.** `script/validate_webgpu.sh` now also runs the 3D GPU
suites on WebGPU (Dawn over Metal here), compares against checked-in WebGPU
references (`GoldenFrames/webgpu`), and runs `GoldenBackendAgreementTests`,
which compares the Metal and WebGPU references: all 26 shared frames are
currently identical (wireframe is excluded because the WebGPU encoder ignores
fill mode). Tint, Dawn and the SPIR-V to WGSL path accepted every new shader
(bloom, auto exposure, depth of field, debug view, tone mapping and grading
includes). The temporal path exists only on Metal, so its tests are skipped on
WebGPU. All GPU suites live under one serialized parent suite
(`Render3DGPUTests`) because the engine owns a single process-wide renderer and
main-actor tests interleave at each `await`; the validation script runs its
package with `--no-parallel` for the same reason. Backend selection is
`ADAENGINE_GOLDEN_METAL=1` or `ADAENGINE_GOLDEN_WEBGPU=1`; the suites were renamed
from `...MetalTests` to `...GPUTests`.

**Two shader-pipeline bugs found and fixed.**

- `ShaderIncluder` matched module include names greedily, so two adjacent
  `#include <...>` lines (or any later line ending in `>`) failed to resolve.
- `ShaderCache` keyed compiled shaders by the shader's own text, so editing an
  included file silently reused the stale compiled shader. The key now hashes the
  text after include expansion, using the compiler's full include search paths
  (the compiler adds the engine's `AdaEngine` module itself).

**Tests worth knowing.** Temporal renders keep accumulating history, so
self-comparisons on that path are held to the drift two untouched renders show.
The temporal jitter period is eight frames, so equal-length renders land on the
same phase.

**Validation (second pass).** Metal: all GPU suites pass, repeatedly. WebGPU:
`script/validate_webgpu.sh` passes (114 tests). The full engine suite passes
apart from two issues outside this work: `AdaUITests` crashes on
`WindowFrameRequests is not stored in world` in the "Window routing blocks a UI
press" test, and `Physics3DTests.fixedSchedulerAdvancesAndWritesBackDynamicBody`
fails under parallel load but passes alone. Not verified: Apple mobile, Windows
(the GPU suites are macOS-only), the windowed presentation notification path.

### Stage 5, first slice: distance and height fog (2026-10-18)

`Environment3D.fog` (`Fog3D`) adds exponential height fog with distance start, maximum opacity, optional sky
influence and sun in-scattering. It is evaluated in `screen_space_reflection.glsl`, in linear HDR on the lit
color and before exposure, bloom add, grading and tone mapping, so it follows exposure like any other light.
Optical depth is the analytic integral of `density * exp(-heightFalloff * (y - baseHeight))` along the view
ray (uniform distance fog when `heightFalloff` is `0`). It costs one extra branch per pixel when off and
allocates nothing. Sky pixels are untouched unless `skyInfluence` is above zero. Sun in-scattering reads the
primary directional light's radiance and direction. SSR-traced reflection hits are not fogged separately
(the fog applies to the final composited pixel). Tests: `Render3DFogSettingsTests` and
`Render3DGPUTests/Fog` (Metal passes, with the `pbr-spheres-fog` golden frame recorded; WebGPU references are not yet recorded because they need `script/validate_webgpu.sh` with Swan/Dawn and Swift 6.3.2).

### Stage 5, second slice: volumetric light shafts (2026-10-18)

The ADR first named froxel volumetrics. This slice uses the approach Bevy ships (a full-screen raymarch that
samples shadow maps) instead of Godot's compute froxel grid: it needs no compute path, so it works on every
backend the main pass does, and it reuses the cascaded sun shadows already rendered.

`Fog3D.volumetric` (`VolumetricFog3D`: intensity, anisotropy, steps, maximum distance) enables
`VolumetricFog3DRenderNode`, which runs after `Main3D` and before the composite. Per half-resolution pixel it
marches the view ray to the surface (or to `maxDistance` for sky pixels) with interleaved-gradient jitter,
integrates the fog medium (the same density and height falloff as the analytic fog), looks up the covering
sun cascade and accumulates `density * transmittance * visibility`, scaled by a Henyey-Greenstein phase and the
sun radiance. The composite adds the bilinearly upsampled result in linear HDR, and the unshadowed analytic
`sunInscattering` term switches off while shafts run. A camera without active shafts allocates no texture
(`VolumetricFog3DViews`) and records no pass.

The upsample weights the four surrounding half-resolution texels by bilinear distance and by how close their
view depth is to the full-resolution pixel's (sky counts as very far), so shafts do not bleed across silhouettes.

**Cost (Apple M-class GPU, 1080p, release, 400-sphere benchmark scene, best of 3 rounds).** Analytic fog is free
(`free` 2.43 ms bare, 2.45 ms with fog). Light shafts add 0.26 ms GPU for the pass at 16 steps (`free` 2.69 ms)
and 0.65 ms at 48 steps (`free` 3.09 ms). Reproduce with `ADAENGINE_PERF_FILTER='bare,fog,shafts'`.

Limits of this slice: sun only (no point or spot lights, no fog volumes), one shadow tap per step, no temporal
accumulation (the jitter shows as fine noise), and no WebGPU validation yet. Tests: `Render3DGPUTests/Fog` (additive light, shadows carving the shafts, texture
release, `pbr-spheres-light-shafts` golden frame on Metal).

### Stage 6, first slice: tiled local lights (2026-10-18)

Measured before building: on the benchmark scene the per-pixel loop over 8 local lights cost 0.47 ms (geometry
1.71 ms against 1.24 ms without local lights) and over 32 lights 1.33 ms (2.57 ms). The local shadow pass is
a separate 1.10 ms for 13 faces, which this slice does not touch.

The CPU now bins the (up to 32) local lights into screen tiles of at least 32 pixels (the size doubles until
there are at most 4,096 tiles, so 1080p is 60 by 34 tiles and 4K is 2,040 to 8,160 at 64 pixels).
Each tile holds a 32-bit light mask; a light sets the bits of the tiles its view-space bounding box projects
onto, plus one pixel of margin. A light whose sphere reaches the camera plane marks every tile. The main pass
projects the fragment's view-space position with the same matrix to find its tile (so the lookup does not depend
on a backend's fragment-coordinate origin), then loops only over the set bits. The masks are conservative: a
light outside its range already contributed zero, so the lit image is unchanged. `Environment3D.tiledLocalLights`
(on by default) falls back to the flat loop, and foveated rendering keeps the flat loop.

**Results (same machine and method as Performance pass 1).** With 32 local lights geometry went from 2.57 ms to
2.09 ms and `free` from 3.30 ms to 2.81 ms. With 8 lights the change is within noise (1.71 ms to 1.69 ms),
so this helps scenes with many lights, not typical ones. The remaining 0.83 ms at 32 lights is mostly real
shading: the benchmark lights overlap heavily (range 5 at 4 unit spacing), so each pixel still evaluates several.

Not done: depth slicing into clusters (a tile still lists lights that are in front of or behind the surface),
tighter bounds for spot cones, and a limit above 32 local lights. Those only pay off with many overlapping
lights at different depths. Tests: `Render3DLightTilesMathTests` (bounds, near-plane handling, viewport offset,
32-light cap), `Render3DGPUTests/LightTiles` (tiled and flat frames match; the test fails when the mask is
broken) and the `32 lights` benchmark configuration.

### Stage 6, second slice: reusing unchanged local shadow faces (2026-10-19)

Every frame the local shadow pass cleared the atlas and redrew all faces (13 faces, 1.10 ms in the benchmark scene)
even when nothing near a light had moved. Now each face keeps what it drew:

- `VisibleMesh3DLists` fingerprints every shadow pass it prepares (`shadowDigest`): the batch key of each batch
  (mesh part buffers, material parameter buffer, base color texture, skin), each caster's transform, color factor and
  fade. A pass with a skinned caster has no fingerprint, because a pose changes without any visible change on
  the CPU, so those faces are always redrawn.
- `LocalShadow3DRenderNode` combines it with the face's view-projection matrix (the light's position, direction, range and
  cone) and compares it with the one stored for the same atlas tile. If every face matches, the pass is skipped
  entirely. Otherwise the atlas is loaded rather than cleared, each dirty tile is reset with a small
  scissored clear draw and then redrawn, and clean tiles are left alone. A new atlas or a different budget starts
  from scratch. `LocalShadowSettings3D.reusesStaticFaces` (on by default) turns it off, and
  `Render3DLightStatistics.Snapshot.reusedShadowFaces` reports how many faces the last frame kept.

**Result (same machine and method).** On the static benchmark scene the local shadow pass goes from 1.10 ms to
0 ms and `free` from 2.39 ms to 1.90 ms. Preparing the per-face visible lists still runs on the CPU every frame
because the fingerprint comes from it. A moving light dirties all of its faces; a moving caster dirties only the
faces whose frustum it enters or leaves.

**CPU follow-up.** Fingerprinting a face needed its visible list, so the node still prepared every face each frame.
`ShadowSceneDigest3D` now fingerprints the shadow casters once per frame (transform, mesh part buffers, material
identity and revision, base color texture). While that digest and a face's matrix are both unchanged, the face
is kept without building its list; when the digest changes, every face is prepared and compared by content as
before, so a caster that moves still dirties only the faces it touches. A scene with skinned casters, or with
level-of-detail alternatives while LOD is on (the chosen mesh follows the camera), has no digest and keeps the
per-face path. Measured on 4,900 meshes the node's CPU time per frame went from 0.49 ms to 0.21 ms; the frame
itself is GPU-bound there (`free` 7.4 to 7.5 ms either way), so the saving shows on CPU-bound machines and
scenes, not in the benchmark's frame time. The digest is now the main remaining cost (about 40 ns per caster); an
extraction-time change counter would remove it.

Limits: meshes edited in place (same buffers, new vertices) are not noticed; a caster that animates only through
skinning keeps its faces dirty every frame; the directional cascades (0.53 ms) are not cached, since they follow
the camera. Tests: `Render3DShadowFaceCacheSettingsTests`, and `Render3DGPUTests/ShadowFaceCache` (a static scene
keeps all faces and looks identical to a redraw, a moved caster dirties some but not all faces and the partly
reused atlas equals a full redraw, a moved light dirties every face).

### Stage 2, first slice: texture transforms, IOR, specular and the extension policy (2026-10-19)

**Correction to G2.** The audit said the loader "rejects" extensions it does not know. It only rejects those a file
lists in `extensionsRequired`, which is what the glTF specification asks for; extensions listed only in
`extensionsUsed` were already ignored, silently. The gap was the silence, not a rejection.

- **Policy.** `NativeGLTFLoader.supportedExtensions` is the public list (`KHR_mesh_quantization`,
  `KHR_materials_emissive_strength`, `KHR_texture_transform`, `KHR_materials_ior`, `KHR_materials_specular`). A file that
  *requires* anything else still fails with `unsupportedRequiredExtension`. An extension a file merely *uses* is
  ignored and reported in `GLTFImportResult.warnings`, as is a `KHR_materials_specular` texture (only the factors are
  read). `ModelAsset3D.importWarnings` carries them to the engine; nothing is logged yet because `AdaScene` has no
  logging dependency.
- **`KHR_texture_transform`** for base color, metallic/roughness, normal, occlusion and emission: offset, rotation, scale and
  the `texCoord` override. `PBRMaterial.textureTransforms` holds five `PBRTextureTransform`s; the material uniform stores each
  as a 2x2 matrix and an offset, and `flat3d.glsl` applies it in `materialUV`. The directional-shadow and motion shaders
  apply the base-color transform to their alpha test, so cut-out shadows and motion vectors follow the texture. A normal map
  whose transform rotates or flips axes stops using authored tangents (the derivative frame follows the transformed UVs).
- **`KHR_materials_ior` and `KHR_materials_specular` (factors).** Non-metal reflectance at normal incidence is
  `min(((ior - 1) / (ior + 1))^2 * specularColor, 1) * specularFactor`, computed on the CPU into `PBR3DUniform.dielectric`
  and used in place of the fixed 0.04 in the direct, local-light and image-based terms. The defaults give 0.04, so
  existing frames are unchanged (all golden frames still match). The glTF specular `F90` term is not modeled (full
  white at grazing angles, as before), and the SSR composite keeps its own fixed reflectivity.
- **Validation.** Malformed transforms (wrong vector length, UV set above 1) and out-of-range reflectance (IOR outside
  1...100, negative or short specular values) fail with `invalidMaterial`.

Cost: the per-material uniform grew from 80 to 272 bytes and the deduplication key from five to sixteen vectors; the benchmark
frame (`bare`, 1.91 ms) is unchanged. Tests: `GLTFMaterialExtensionTests` (import, validation, warnings, the required-extension
failure), `GLTFMaterialExtensionMappingTests` (importer to `PBRMaterial`), `Render3DMaterialExtensionConstantTests` and
`Render3DGPUTests/MaterialExtensions` (a transform moves, scales and rotates the texture, a full turn is the identity, higher IOR
brightens and zero specular dims the highlight, a red tint shifts it, defaults change nothing). Not validated on WebGPU (no
Swan/Dawn here). Still open in Stage 2: clearcoat, sheen, anisotropy, specular textures and `KHR_lights_punctual`.

### Stage 2, second slice: clearcoat (2026-10-19)

`KHR_materials_clearcoat` adds a clear lacquer layer over the base surface (car paint, varnished wood, nails).
`PBRMaterial.clearcoatFactor` and `clearcoatRoughnessFactor` come from the glTF factors (0 to 1, validated on import) and
reach the shader through `PBR3DUniform.coat`. Following the glTF layering model, in `flat3d.glsl`:

- the coat is a dielectric layer (reflectance 0.04) shaded with its own GGX lobe and roughness on the **geometric normal**
  (the normal map belongs to the base layer);
- every light (the sun, extra directional lights and local lights, through `evaluateDirect`) adds the coat's highlight and
  dims the base layer under it by `1 - strength * F(N.V)`, so energy is conserved;
- with image-based lighting the coat also reflects the environment along the geometric normal, using the BRDF
  lookup at the coat's roughness, and dims the base IBL by the same transmission;
- with only the flat ambient, the ambient term is dimmed by the same transmission.

A material with no coat takes one branch on `g_Clearcoat.x`. Measured against the merge commit without this change (1080p, Apple
M-class, release): `bare` geometry 1.77 to 1.82 ms and 2.18 to 2.26 ms with 32 lights, about 3 to 4 percent. For reference
the parallax merge from `main` had already moved `bare` geometry from 1.69 to 1.77 ms.

Limits: the clearcoat, clearcoat roughness and clearcoat normal **textures are not read** (the importer reports them in
`GLTFImportResult.warnings`), because the main pass has no free texture slots on Metal. The screen-space reflection composite
reflects the procedural sky from the base layer's roughness only, so without image-based lighting the coat shows light
highlights but not a sky reflection. There is no clearcoat debug view and no WebGPU validation. Tests:
`GLTFMaterialExtensionTests` (import, ranges, texture warning), `Render3DMaterialExtensionConstantTests` (uniform),
`Render3DGPUTests/MaterialExtensions` (a smooth coat adds a highlight to rough paint, a rougher coat dims it, the highlight grows
with strength, turning the coat off restores the frame) and the `pbr-sphere-clearcoat` golden frame (Metal).

### Stage 2, third slice: sheen and anisotropy (2026-10-19)

`KHR_materials_sheen` (cloth) and `KHR_materials_anisotropy` (brushed metal, satin) factors. `PBRMaterial` gains
`sheenColorFactor`, `sheenRoughnessFactor`, `anisotropyStrength` and `anisotropyRotation`, imported with range
validation (sheen color and roughness 0 to 1, strength 0 to 1) and carried in `PBR3DUniform.sheen` and `.anisotropy`.

- **Sheen.** The Charlie distribution with the Neubelt visibility term, as in the glTF specification, evaluated per light in
  `evaluateDirect`; the base layer under it is dimmed by `1 - max(sheenColor) * 0.4`. The specification's sheen albedo lookup
  table is replaced by that constant (0.4), and under image-based lighting sheen is a diffuse lobe from the irradiance map
  with the same albedo. Without image-based lighting only the lights produce sheen.
- **Anisotropy.** Anisotropic GGX (distribution and height-correlated visibility) with `alphaT = mix(alpha, 1, strength^2)`
  along the stretch direction and `alpha` across it, so the highlight streaks perpendicular to the direction. The frame
  is the authored tangent when the mesh has tangents and the UV-derivative frame otherwise, rotated by
  `anisotropyRotation`. Image-based reflections bend the lookup normal toward the stretch (the Filament approximation).
- **Layering order** is base, then sheen, then clearcoat. The sun now goes through `evaluateDirect` like every other light, which
  removed the duplicated inline copy of the lighting model.

**Cost (same machine and method).** With every layer switched off, `bare` main-pass geometry went from 1.77 ms at the merge
with `main` to 1.82 ms with clearcoat and to 1.92 ms with sheen and anisotropy (32 lights: 2.18, 2.26, 2.40 ms), so the
three layered-material features together cost about 8 percent of main-pass geometry on scenes that use none of them. The
branches are uniform across a draw, so the cost is most likely register pressure from the larger lighting function. The fix
is shader permutations selected by the material (the `HAS_...` define mechanism exists on `PBRMaterial`, but the PBR
pipeline is keyed by vertex layout only), which is not done.

Limits: the sheen color, sheen roughness and anisotropy textures are not read (reported as import warnings). Meshes
without tangents get a tangent frame from UV derivatives, which is constant per triangle and shows faceting along an
anisotropic highlight on coarse meshes (visible on the primitive sphere in `pbr-sphere-anisotropy`) and at UV poles; assets with
authored tangents do not show it. No WebGPU validation. Tests: import, ranges and warnings in `GLTFMaterialExtensionTests`,
the uniform in `Render3DMaterialExtensionConstantTests`, and in `Render3DGPUTests/MaterialExtensions` sheen adds light that
grows with its color and tints it, turning it off restores the frame, anisotropy changes and rotates the highlight and a half
turn looks the same, plus the `pbr-sphere-sheen` and `pbr-sphere-anisotropy` golden frames (Metal).

### Stage 2, fourth slice: main shader specialized by shading layer (2026-10-19)

The third slice left layered materials costing about 8 percent of main-pass geometry even when no material used a layer.
The main shader is now specialized by material:

- `PBRMaterial.shaderFeatures` is the set of layers a material uses (`clearcoat`, `sheen`, `anisotropy`, derived from the
  factors, so editing a factor at run time changes it). `PBR3DConfiguration.features` joins the pipeline key, and
  `Flat3DPipeline` takes the matching fragment shader from `PBR3DShaderVariants`.
- In `flat3d.glsl`, `hasClearcoat()`, `hasSheen()` and `hasAnisotropy()` are constant `false` unless `ADA_CLEARCOAT`,
  `ADA_SHEEN` or `ADA_ANISOTROPY` is defined, so the plain shader has none of the layer code. Names that enable a layer, not
  ones that remove it, so the file with no macros is the plain shader.
- `ShaderModule.createBundled(at:from:defines:)` compiles a variant from the file's text. That bypasses the on-disk shader
  cache, which is keyed by file and stage (its manifest, reflection and device-compiled entries would otherwise be overwritten
  by every variant), so a variant compiles in the process on first use, and about 1 second on this machine. The plain shader,
  used by almost every material, keeps the disk cache. The first attempt had the macros remove the layers, which made
  the common variant a runtime compile too, and the GPU test suite went from 12 s to 51 s; it was reversed.

**Result (1080p, Apple M-class, release).** `bare` main-pass geometry 1.92 ms with the layers in every material back to 1.77 ms,
the level before any layer (32 lights: 2.40 to 2.17 ms). Layered materials pay the full layer cost only where they are drawn.

Limits: WebAssembly builds ship precompiled WGSL and cannot specialize, so on the web there are no layers (the plain module is
used); the motion and shadow passes do not use layers and are not split. The first draw of each new layer combination compiles
a shader. Tests: `shaderFeaturesFollowTheLayersInUse`, `pipelineKeysSplitByFeaturesAndDefaultToThePlainShader`, and the existing
clearcoat, sheen and anisotropy GPU tests, which now run through the variants (turning a layer off restores the plain frame).

### Stage 2, fifth slice: layer textures (2026-10-19)

The clearcoat, sheen, anisotropy and specular extensions now read their textures, which the earlier slices skipped. Eight textures
(`PBRLayerTexture`): clearcoat strength (red), clearcoat roughness (green), clearcoat normal, sheen color (RGB, sRGB), sheen
roughness (alpha), anisotropy direction (red and green) with strength (blue), specular strength (alpha) and specular color
(RGB, sRGB). Each multiplies its factor, as the extension texts require.

- **Import.** Each reference keeps its texture, UV set (0 or 1, or the `texCoord` of its own `KHR_texture_transform`), transform
  and, for the clearcoat normal map, its scale (`GLTFImportResult.LayerTextures`). A bad index, UV set or transform fails with
  `invalidMaterial`. Import warnings for skipped layer textures are gone because none are skipped.
- **Binding.** Textures bind at 32 to 39, and only in the shader variant of a material that has them: `PBRMaterial.shaderFeatures`
  gained one bit per texture (macros `ADA_CLEARCOAT_TEXTURE` and so on), and a texture selects its bit only while its layer is
  on, because it scales a factor that would otherwise be zero. The specular textures belong to no layer. So a material pays for the
  textures it has, and the plain shader and the bind groups of other materials are unchanged (`bare` geometry is still 1.77 ms).
- **Sampling.** The main pass has no free sampler slot (Metal allows 16), so every layer texture is read with the base color
  texture's sampler: a layer texture whose glTF sampler differs from the base color's (for example another wrap mode) takes the
  base color's. UVs come from `layerUV`, which applies the parallax shift of the same UV set and then the texture's transform. The
  material uniform carries each texture's UV set and transform (about 330 more bytes per material).
- **Shading.** Clearcoat strength and roughness are scaled by their textures, the clearcoat normal bends the coat on its own
  frame (derivative frame; the base normal map is untouched), sheen color and roughness are scaled, the anisotropy texture sets
  the direction (rotated by `anisotropyRotation`) and scales the strength, and the specular textures scale the dielectric
  reflectance `g_Dielectric`, which replaced the uniform value in every lighting term.

Limits: the layer textures share the base color sampler; the clearcoat normal map uses the UV-derivative frame (no authored
tangents), so it shares the faceting of that frame on coarse meshes; there is no web build of any layer (variants cannot be compiled
there). Tests: import (`importsEveryLayerTextureWithItsOwnUVSetAndTransform` and the rejection cases), the mapping from an
imported material to `PBRMaterial`, the feature bits and uniform, and one GPU test per texture. They include equivalences (an
anisotropy texture of (1, 0.5, 1) equals the factor alone, and (0.5, 1, 1) equals a quarter turn; a specular alpha of zero equals a
specular factor of zero; a flat clearcoat normal changes nothing) and a transform test that samples either half of a two-tone mask.
Each of the shader reads was checked by removing it and watching its test fail.

### Stage 3, first slice: morph targets (2026-10-19)

**Import.** Primitives carry `targets` (POSITION, NORMAL and TANGENT deltas per vertex; sparse accessors expand to dense), meshes carry
the default `weights` and the `extras.targetNames` convention, nodes may override the weights, and animation channels with the
`weights` path import with one value per target and key. Inconsistent data fails with `invalidMorphTargets`; morphed
attributes other than the three deltas are reported as warnings.

**GPU evaluation.** `MorphTargetSet` packs every target's deltas into one RGBA16F texture (`Part.morphTargets`): texel
`(target * vertices + vertex) * attributes + attribute`, 2048 texels wide, up to 8192 rows (about 16.7 million texels of
targets x vertices x attributes; a mesh past that fails to load with an explicit error). A draw applies at most 8 targets, the
ones with the largest weights (`MorphTargetSet.activeTargets`), and its vertex shader fetches only those deltas with `texelFetch`
(`Morph.glsl`, behind `ADA_MORPH`, so unmorphed meshes keep the plain shaders), so cost follows the active targets and memory follows all
of them. Deltas are half precision (portable bit conversion, no `Float16`). The weights live in `Morph3DUniforms`, one buffer per entity
and mesh part (parts differ in vertex count), holding the current and the previous frame's active targets.

**Passes.** The morph feature (`PBRMaterial.ShaderFeatures.morph`, a property of the draw, not the material) selects a vertex
shader variant of the main shader, the motion shader and the directional and local shadow shaders (`Shadow3DConfiguration` joins the
pipeline key) and the occlusion prepass; weights and the delta texture bind at 21 and 40. Order is morph, then skin (the
deltas move the rest pose before the joint matrices). The motion pass moves a vertex from where the previous weights put it.

**Culling, batching and caches.** The source bounds grow by the most the active weights can displace (the largest delta of each
active target times its weight, times the largest joint scale for skinned meshes), so frustum culling, shadow culling and the occlusion
candidates see the morphed shape. A morphed mesh is its own batch (like a skinned one), has no level-of-detail
alternatives, and counts as dynamic for the shadow face cache. `MorphWeights3DComponent` holds the weights (with `setWeight(_:named:)`),
and `ModelAsset3D.instantiate` adds it with the file's default weights.

**Tests.** Import (`GLTFMorphTargetImportTests`, 11 cases); packing, selection and uniform layout (`Render3DMorphTargetSelectionTests`);
and GPU tests (`Render3DGPUTests/MorphTargets`): weight zero equals the unmorphed mesh, a weighted shift equals moving the entity (sun and
local-light shadows included), only the heaviest eight targets apply, weight changes update the shadow faces on the first frame, a mesh
resting off screen is not culled once morphed, normal deltas change shading but not the silhouette, the occlusion prepass and the
temporal motion pass draw the morphed shape, the uniform keeps the previous frame's weights, and a glTF skinned to a joint turned a quarter turn
applies its morph before the skin. Each shader read was checked by breaking it and watching a test fail.

Limits: deltas are dense and half precision (no sparse or compacted storage, so a face with many targets costs texture memory
in proportion to targets x vertices); the selection is made per frame on the CPU; only POSITION, NORMAL and TANGENT morph; layered materials
and morph share the shader-variant mechanism, so the first draw of a morphed mesh compiles its variants (about a second each), and there is no web
build. Not done at this slice: playing `weights` channels, AdaScript and the Editor (see the second slice).

### Stage 3, second slice: animated weights and script access (2026-10-19)

**Clips.** glTF `weights` channels import as `MorphWeightsTrack` (a validated track of `targetCount` weights per key, linear,
step or cubic spline with per-target tangents scaled by the key span, sampled without allocating) in `SkeletalAnimationClip.morphTracks`;
they count toward the clip duration and are valid on matrix-placed nodes. A rig node carries `morphRestWeights` (the node's weights, else the
mesh's defaults), and a player rejects a track that addresses a node with a different target count.

**Playback.** `SkeletalAnimationPlayer.morphWeights` holds the weights by rig node (empty where the node has no targets). Without a graph a
clip's tracks overwrite the rest weights at its local time, looping and clamping like poses; a crossfade (`transitionDuration`)
interpolates from the weights at the time of the switch. In a graph, blend nodes mix weights by input weight and mask with the rest weights
filling a gap (a mask is read at the mesh node's rig index), and additive nodes add each further input's offset from the rest weights,
the same rules the poses follow.

**Scene.** `SkeletalAnimation3DSystem` writes `player.morphWeights` into the node's `MorphWeights3DComponent` whenever the pose generation
changes, only for nodes the animation drives (matching, non-empty weights), so hand-set weights on other nodes are not touched. The
renderer already treats weight changes as dynamic (shadow faces, bounds, previous-frame weights), so animated morphs need nothing more.

**Scripts.** `MorphWeights3DComponent` is a reflected `@Component`, registered with the model plugin and Codable (a missing key
decodes to its default). Reflection exposes scalars only, so arrays show as read-only fields; scripts and the inspector steer one target at a
time through `selectedTarget`, `selectedTargetName` (assigning a name selects that target) and `selectedTargetWeight` (assigning a finite
value sets the weight), and code uses `weights` and `setWeight(_:named:)`.

**Tests.** 17 CPU tests (`MorphWeightsAnimationTests`): sampling and rejection, the player (rest weights, clip, loop and clamp, independent
players, crossfade, track validation, duration), and the graph (blend with rest fill, mask on the mesh node, additive, clips without
weight tracks). A GPU test loads a glTF with an animated weights channel through `ModelAsset3D`, seeks to half a second, checks that the
entity holds `[0.5]`, that the frame equals the same weight set by hand, and that the end of the clip applies the full shift; reflection
and Codable tests cover the component.

Not done: an Editor panel (the Editor package keeps its own component catalog and builds separately) and animating weights from keyframe
`AdaAnimation` clips (only glTF clips and the skeletal graph drive weights); an AdaScript sample.

### Stage 3, third slice: authored weights and the Editor panel (2026-10-19)

**Where weights live in a scene.** A model in a scene is a `Model3DSource` that instantiates a hierarchy at run time, so the weight
components exist only on generated children. `Model3DSource.morphWeights` (target name to weight, absent in older scenes) is applied at
instantiation to every mesh with a target of that name, which is what an Editor can author. They are the weights the instance
starts with and keeps unless a clip animates that mesh's weights: `SkeletalAnimation3DSystem` now writes player weights only to
nodes some clip animates (`SkeletalAnimationPlayer.animatedMorphNodes`). Before that, a rigged model's rest weights from the file
would have overwritten authored ones on the first frame.

**Editor.** The Animator panel has a Morph Targets mode next to the skeletal graph and keyframes. It loads the model, lists its *named*
targets (a model's unnamed targets are counted and reported as not addressable from a scene) with one slider each from 0 to 1,
shows the result live in the preview (`EditorModelAssetPreviewModel.morphWeights`), and applies it as one undoable scene transaction
(`setMorphWeights`), stored as a structured `morphWeights` map on the Model 3D component (a weight equal to the file's default is not an
override, and an empty map removes the key). Reset clears the overrides. Names the model does not have are dropped when it loads.

**Tests (Editor package, built with Xcode's toolchain).** Six run and pass: the model (targets, defaults, clamping, unnamed targets), the payload,
a scene transaction that saves, reopens, decodes through the component registry, undoes, redoes and clears, the preview applying and
undoing weights, and the weight list drawing one named slider per target. A seventh (`loaderAppliesAuthoredWeights`) opens the saved scene
through `EditorSceneFileLoader` and checks the instantiated entity's weights; it did not run here, because on this machine any Editor test that
goes through that loader ends the test process silently, the existing `EditorAnimationGraphTests` scene round trip included. The same behavior is
covered on the runtime side by `authoredWeightsStartTheInstanceAndYieldToAnimation`.

Not done: slider interaction is covered through the model and workbench, not by driving the slider with simulated pointer events; the Environment 3D inspector does not yet list the fog, light-shaft, tiled-light or shadow-cache settings added earlier in this work; weights
cannot be keyframed in the Editor's keyframe animator (only glTF clips and the skeletal graph animate them).

## Validation requirements

Use Swift Testing for logic (settings decoding, extension gating, budgets,
history reset, ordering) and the Stage 0 golden-frame harness for pixels. Every
visual change records a native capture on at least Metal; web-targeted shaders
also record `script/validate_webgpu.sh` results. Record separately: source
tests, native GPU pixels and other-platform coverage.

Per stage, additionally verify:

- **Post stack:** disabled effects change no pixels and allocate nothing;
  existing scenes render identically at default settings; UI is unaffected by
  exposure and bloom; multiple cameras keep independent settings and history.
- **Materials/glTF:** old scenes and payloads decode and render unchanged;
  Khronos sample models for each extension match reference renders within
  tolerance; unsupported required extensions fail with a clear error.
- **Morph targets:** zero weights are bit-identical to the unmorphed mesh;
  morph plus skin, shadows and motion vectors agree with a CPU reference.
- **Transparency:** intersecting blended meshes show no ordering artifacts in
  OIT mode; fallback matches current behavior; transmission handles roughness
  and IOR cases without NaNs or negative colors.
- **Atmosphere:** energy is conserved across sun angles; fog and sky do not
  shift tone-mapped output of scenes with them disabled; sky-driven IBL updates
  stay within the stated budget.
- **Lighting scale:** clustered assignment matches the flat loop output on a
  reference scene; record frame time and memory at 8, 32 and above-limit light
  counts.
- **Content features:** each reports CPU time, GPU time, upload bytes and
  memory on a realistic scene, per ADR-0022's rule that fewer draw calls or
  allocations alone are not an improvement.

## Consequences

This ADR is a proposed roadmap, not evidence of shipped behavior. It becomes
Accepted when the owner confirms the priority order. Stage items that overlap
ADR-0017, ADR-0019, ADR-0020 and ADR-0021 are tracked in those ADRs'
checklists; update both places when one changes. Large stages (Stage 5, 6 and 7)
should be split into their own ADRs when design work begins, and this ADR
should then link to them and keep only the summary.
