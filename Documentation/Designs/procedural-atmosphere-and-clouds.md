# Procedural Atmosphere and Volumetric Clouds

Status: **Proposed for human approval.**
Approval: none yet. Implementation and planning wait for explicit approval.
Date: 2026-11-16.
Classification: feature (a new sky subsystem). It extends `Environment3D` and the main 3D render graph.
Related: [ADR-0019 environment lighting and post-processing](../ArchitectureDecisions/0019-environment-lighting-and-postprocessing.md),
[ADR-0027 3D rendering gap roadmap](../ArchitectureDecisions/0027-3d-rendering-pipeline-gap-roadmap.md),
[Dynamic GI guide](../DynamicGI.md). A new ADR (0030) records the decisions in §4 after approval.

## 1. Problem

The sky is a three-colour gradient (zenith, horizon, ground), an optional equirectangular texture and an
optional star field. All of it is drawn by the full-screen `environment_composite` pass
(`Sources/AdaCorePipelines/Assets/Shaders/environment_composite.wesl`). Consequences:

- No time of day. Moving the sun does not change the sky colour, so sunsets need hand-tuned colours.
- No aerial perspective. Distant terrain and trees are not tinted blue and hazed by the air between them
  and the camera. The only depth cue is the exponential height fog.
- No clouds. Open-world scenes (terrain, forests) look empty and flat above the horizon.

Reference quality: a forest and meadow scene with soft volumetric clouds, hazy distant hills and
sun-dependent colour, running at 60 fps with a GPU budget under 8.5 ms in total.

## 2. Decisions settled during Enrich (2026-11-16)

| ID | Decision |
| --- | --- |
| E1 | One design covers atmosphere and clouds. Delivery is staged: atmosphere first (§6, stage A), clouds second (stage B). |
| E2 | The sky is **physically based and driven by the sun**: Rayleigh and Mie scattering plus ozone absorption, computed from the primary directional light. Artist overrides stay available. |
| E3 | Clouds are **raymarched volumetric** clouds, rendered at reduced resolution with temporal reprojection. A cheaper low tier exists (§4.6). |
| E4 | Targets are **all SAGA platforms** (Vulkan, Metal, WebGPU browser host) with quality tiers. No platform is excluded. |

## 3. Goals and non-goals

| ID | Goal |
| --- | --- |
| G1 | The sky colour, sun disc, horizon glow and sunset follow the primary directional light's direction. |
| G2 | Geometry is tinted by aerial perspective that is consistent with the sky behind it. |
| G3 | Clouds are lit by the sun and the sky, have soft edges and visible depth, and drift with wind. |
| G4 | Scenes that do not enable the feature render **pixel-identically** to today, and existing saved scenes load unchanged. |
| G5 | Rendering is deterministic for a given settings value and explicit time, so golden-frame tests are possible. |
| G6 | The cost is bounded and measured per tier (§7), and scales down for web and mobile. |

Non-goals (separate designs):

- Cloud shadows on the ground, god-rays through clouds, and rain or storm weather.
- Planetary-scale or space views (the camera stays inside the atmosphere; cloud layer is a flat slab).
- A moon with phases and a full night-sky model beyond the existing star field.
- Baked sky captures for reflection probes, beyond what §4.4 specifies for ambient light.
- Terrain, vegetation and foliage shading. They are separate roadmap phases that consume this feature.

## 4. Design

### 4.1 Public API (AdaCorePipelines)

`Environment3D` gains two optional-by-default settings, both `Codable`, `Sendable`, with
`decodeIfPresent` fallbacks to the defaults so old scenes decode unchanged:

- `atmosphere: Atmosphere3D` (default `isEnabled = false`).
- `Atmosphere3D.clouds: VolumetricClouds3D` (default `isEnabled = false`). Clouds require the atmosphere to be
  enabled; they are ignored otherwise.

`Atmosphere3D` carries: `isEnabled`, `intensity` (sun and sky radiance multiplier), `rayleighScale`,
`mieScale`, `mieAnisotropy`, `ozoneScale`, `groundAlbedo`, `groundRadiusMeters`/`atmosphereHeightMeters`
(Earth-like defaults), `sunDiscScale`, `sunDiscIntensity`, `aerialPerspectiveScale`,
`aerialPerspectiveMaxDistance`, `quality: AtmosphereQuality3D`, and a `fallbackSunDirection` used when the
scene has no directional light. A `sanitized` value clamps every field, following `ContactShadows3D`.

`VolumetricClouds3D` carries: `isEnabled`, `coverage`, `density`, `cloudType` (stratus to cumulus),
`baseAltitudeMeters`, `thicknessMeters`, `windDirection`, `windSpeed`, `detailScale`, `lightingScale`,
`ambientScale`, `time` (seconds, optional explicit override for deterministic frames), `seed`,
and `quality: CloudQuality3D`.

`AtmosphereQuality3D` and `CloudQuality3D` are `low`, `medium`, `high`. The default is chosen per platform
(§5), and the author can override it. Flat reflected accessors on `Environment3D` follow the existing pattern
(`atmosphereEnabled`, `cloudCoverage`, ...) so scripts and the inspector reach them.

Precedence with the existing sky:

- Atmosphere enabled: the atmosphere **replaces** the gradient and the equirectangular texture as the visible sky.
  `Skybox3D.zenithColor`, `horizonColor` and `texture` are then not displayed.
- `groundColor` still fills below the horizon only if `groundRadiusMeters` rendering is off; by default the
  planet surface below the horizon is the atmosphere's ground term.
- The star field remains and is faded by sky luminance, so it appears at dusk and night.
- An IBL asset keeps contributing to material lighting exactly as today. `skyboxUsesImageBasedLighting`
  is ignored while the atmosphere is enabled, because the atmosphere is the displayed sky.

### 4.2 Sun and lighting inputs

The sun is the primary directional light already extracted into `ExtractedLighting3D.directionalLight`
(the volumetric fog node reads the same resource). Its direction drives the sky. Its colour and intensity are
**not** overwritten: the atmosphere computes sun transmittance at the camera and exposes it, but applying it to the
light is a separate opt-in (`Atmosphere3D.tintsSunLight`, default `false`) so existing exposure and light setups
are not silently changed. With no directional light, `fallbackSunDirection` is used and no light is modified.

### 4.3 Atmosphere pass

The method follows the published real-time model that precomputes small look-up tables (LUTs):

| Table | Size (medium) | Updates |
| --- | --- | --- |
| Transmittance | 256 x 64 | When atmosphere parameters change |
| Multiple scattering | 32 x 32 | When atmosphere parameters or sun elevation change |
| Sky view (latitude-longitude around the camera) | 192 x 108 | Every frame per camera, when the sun or camera height changed |
| Aerial perspective (camera frustum volume) | 32 x 32 x 16 slices | Every frame per camera |

Rules:

- Each camera owns its sky-view and aerial-perspective tables, with no state shared across views
  (the same rule as `GPUVisibility3DState`).
- `environment_composite` samples the sky-view table for sky pixels, and the aerial-perspective volume for
  geometry pixels, in linear HDR before bloom and tone mapping. Aerial perspective is applied before the existing
  height fog, so the fog remains the local, artist-controlled layer on top.
- Distant geometry beyond `aerialPerspectiveMaxDistance` receives the full table value at that distance.
- The sun disc is drawn analytically with limb darkening and is occluded by clouds and terrain through the
  existing depth and the cloud transmittance.

**Execution model decision (D1, verified 2026-11-16).** The tables are produced by **full-screen fragment passes into
2D `rgba_16f` render targets**; the 3D aerial-perspective volume and the 3D cloud noise are stored as 2D atlases of
depth slices. Verified in the code: `RenderTexture` is 2D only, and the only compute use in AdaRender is the
fixed-purpose visibility and shadow-culling processors, not a general API for render nodes. The existing
`VolumetricFog3DRenderNode` is the working precedent: a fragment pass into a per-camera `rgba_16f` texture, run after the
main pass and before the composite, with a per-view uniform cache and retired-texture handling. SAGA itself exposes
compute, so the passes may later move to compute without changing the public API, the tables or the image.

**Other consumers of the sky (verified).**

- *Temporal anti-aliasing:* `sky_motion_3d.wesl` writes sky motion vectors independently of the sky colour, so it
  needs no change. Cloud history uses its own reprojection (§4.5).
- *Screen-space reflections:* a missed ray falls back to the zenith, horizon and ground colours. With the atmosphere
  enabled, stage A samples the sky-view table in that fallback, so reflections match the displayed sky.
- *Path tracing:* uses its own sky colours and is unchanged (listed as a limitation in the article).

### 4.4 Sky as ambient light

Verified in the code (2026-11-16): the main PBR shader (`flat3d.wesl`) computes ambient light as
`albedo * directional.u_LightRadianceAmbient.w`, a constant fallback, unless an IBL or baked-lighting term replaces it.
The zenith, horizon and ground colours are used only by the displayed sky, screen-space reflection misses and path
tracing, not by diffuse ambient. Feeding a sun-dependent sky term into ambient therefore needs a new uniform in a
1,500-line shader shared by many pipelines. That is a cross-cutting change and **moves out of this design's stages A
and B** into a follow-up improvement ("sky ambient"), which uses small spherical-harmonics coefficients computed from the sky-view table.
Until then, an IBL asset or the existing ambient fallback lights the scene exactly as it does today.

### 4.5 Cloud pass

- **Layer.** One horizontal slab between `baseAltitudeMeters` and `baseAltitudeMeters + thicknessMeters`
  (defaults roughly 1.5 km to 4 km).
- **Density.** Built from a tileable shape noise (Perlin-Worley, 128-cubed equivalent), a detail noise (32-cubed
  equivalent) and a 2D weather map controlled by `coverage` and `cloudType`. The noise textures are generated
  **procedurally at first use** from `seed`, so no binary asset is added to the repository or the build.
- **March.** A fixed budget of view samples (tier-dependent) with a step that grows with distance, and a short
  march of light samples toward the sun for in-scattered light.
- **Lighting.** Beer-Lambert extinction with a "powder" term, a dual-lobe Henyey-Greenstein phase function, a
  multiple-scattering approximation, and ambient light taken from the atmosphere tables (§4.3).
- **Resolution and time.** The cloud pass runs at a reduced resolution (a quarter of the pixels at medium) with a
  per-frame Bayer-pattern sample offset. A history texture is reprojected with the camera motion vectors the
  engine already produces, and clamped by neighbourhood to limit ghosting. A bilateral, depth-aware upsample
  composites the result into the frame.
- **Depth.** Clouds composite over pixels whose depth is beyond the cloud, which in practice is the sky and
  very distant geometry. Aerial perspective is applied to the cloud with the cloud's own distance, so clouds
  haze correctly toward the horizon.
- **Wind and time.** The layer scrolls with `windDirection * windSpeed * time`. `time` is the engine time unless
  `VolumetricClouds3D.time` overrides it, which keeps golden frames deterministic (G5).
- **Camera inside the layer.** The march starts at the camera, so flying through clouds is supported at the
  medium and high tiers.

### 4.6 Quality tiers

| Tier | Atmosphere | Clouds | Intended default |
| --- | --- | --- | --- |
| `low` | Smaller tables, aerial perspective with fewer slices | No raymarch: a 2D scrolling noise layer shaded analytically with the sun | Browser (WebGPU) and mobile |
| `medium` | Sizes in §4.3 | Raymarched, quarter resolution, about 32 view and 4 light samples | Desktop |
| `high` | Larger tables | Raymarched, half resolution, more samples | Opt-in |

All tiers share the same settings and the same visible look direction, so a scene authored on desktop degrades
without breaking.

### 4.7 Ownership

- **AdaCorePipelines** owns the settings types (`Atmosphere3D.swift`, `VolumetricClouds3D.swift`), the render nodes,
  the WESL shaders (`atmosphere_*.wesl`, `clouds_3d.wesl`), per-camera resources and the extraction into
  `ExtractedEnvironment3D`. This matches where fog, SSAO and the sky already live.
- **AdaRender** changes only if Plan step 1 finds a missing backend capability (for example a texture format or a
  compute entry). Such an addition must pass on every backend before it merges.
- **Editor** exposes the new settings through the existing component inspector. If a bespoke control is needed, it
  requires a visual proposal first under the Studio design rules.
- No dependency from AdaRender back to AdaScene or AdaCorePipelines is introduced.

## 5. Platform impact

- Vulkan (Windows, Linux, Android), Metal (Apple) and the WebGPU browser host are all in scope.
- Default tier: `medium` on desktop and `low` on web and mobile.
- WGSL and WESL sources must compile through SAGACompiler for every backend. Atlas textures need only 2D
  render targets with a half-float format; their availability on each backend is verified in Plan step 1.
- The headless build has no graphics device and skips the passes. The settings types still compile, encode and decode.

## 6. Delivery stages

| Stage | Contents | Visible result |
| --- | --- | --- |
| A | Settings, transmittance and multiple-scattering tables, sky view, sun disc, aerial perspective, star fade, SSR sky fallback, tiers, article | Physical sky and hazy distance |
| B | Cloud noise generation, raymarch, temporal reprojection, upsample, low tier layer, article update | Soft volumetric clouds |

Each stage passes the full validation and independent review before the next starts.

## 7. Performance targets

Measured with the existing benchmark (`ADAENGINE_PERF=1 ADAENGINE_GOLDEN_SAGA=1 swift test -c release
-Xswiftc -enable-testing --filter Render3DGPUTests/Benchmarks`) on a quiet machine, per ADR-0027. The reference
machine and resolution are named in the report.

| Tier | Atmosphere GPU cost | Clouds GPU cost | CPU cost |
| --- | --- | --- | --- |
| `low` | under 0.3 ms at 1080p | under 0.3 ms | negligible |
| `medium` | under 0.5 ms at 1080p | under 1.0 ms | under 0.1 ms |
| `high` | reported, not capped | reported, not capped | under 0.1 ms |

These are targets, not measured results. If a target cannot be met, the report states the measured value and the
design returns to the human for a decision. Per-camera table memory is also reported.

## 8. Alternatives considered

| Alternative | Why not |
| --- | --- |
| Keep colour gradients, add a sun-glow term | Cheap, but no sunsets or aerial perspective. It does not reach the requested look (E2). |
| Precomputed sky cubemap or bake from a DCC tool | No time of day without many bakes and large assets. |
| Layered 2D cloud texture only | Flat, no fly-through and weak depth. Kept only as the `low` tier (E3). |
| Voxel or froxel-only clouds | Much more memory and a longer pipeline for the same look at this scale. |
| Ship noise textures as assets | Adds binary files to the repository and the exported builds. Procedural generation avoids that. |
| General compute from the start | Not verified on every backend through AdaRender (D1). The fragment-pass path is the safe default. |

## 9. Risks

| Risk | Mitigation |
| --- | --- |
| A backend lacks a needed texture format or pass capability (D1) | Verified in Plan step 1 on all backends, before coding. Fallback is the lower tier or compute. |
| HDR sky is much brighter than the current gradient and changes exposure | `intensity` default is calibrated against the default exposure; auto exposure is covered by golden frames; documented in the article. |
| Temporal ghosting or flicker in clouds | Motion-vector reprojection, neighbourhood clamp, reset on camera cuts; covered by a motion test. |
| Cost exceeds targets on the browser host | The `low` tier is the browser default; the targets in §7 are measured there too. |
| Interaction with TAA, SSR, fog and path tracing | Ordering is fixed in §4.3; the path-tracing integration is **out of scope** and listed under limitations in the article. |
| Cross-backend golden mismatch | Per-backend references, as for the existing GPU suites. |

## 10. Acceptance criteria

1. **Compatibility.** With the atmosphere disabled, the existing golden frames and the existing
   `Environment3D` Codable fixtures are unchanged, and a scene saved before this change decodes with the feature off.
2. **Settings.** Unit tests cover defaults, sanitization (NaN, infinity, out-of-range), Codable round trip and the
   flat accessors.
3. **Sky.** Golden frames at three sun elevations (noon, 10 degrees, below the horizon) on each supported
   backend match references. A CPU reference implementation of the transmittance integral agrees with the GPU
   table within a stated tolerance at sampled points.
4. **Aerial perspective.** A golden frame shows distant geometry tinted consistently with the sky at the same
   direction (no visible seam at the horizon).
5. **Clouds.** Golden frames with an explicit `time` for low, medium and high coverage. A two-frame motion test shows
   no history ghosting beyond a stated threshold after a camera move, and clouds reset on a camera cut.
6. **Determinism.** The same settings, seed and time give identical frames across two runs on one backend.
7. **Performance.** The benchmark reports GPU and CPU cost per tier on the named machine, compared with §7.
8. **Platforms.** `script/validate_gpu.sh` passes on the available native backend; the browser host and any backend
   not available locally are reported as blocked or covered by named CI, never as passed.
9. **Quality gates.** `python script/check_contribution.py` passes, and an independent review in a separate context
   finds no unresolved findings.

## 11. User documentation

- **Audience.** Game developers and technical artists using `Environment3D`.
- **Article.** A new DocC article in the AdaEngine catalog (`Sources/AdaEngine/AdaEngine.docc/Articles/`), linked from
  the catalog's Topics page. The exact paths are declared with the runner's `documentation` command before
  implementation, as required by the workflow. Existing rendering guides in `Documentation/` (for example
  `DynamicGI.md`) are the style precedent.
- **Contents.** Enabling the atmosphere, driving it from the sun, time-of-day example, clouds, tiers and their
  defaults, cost, interaction with fog, IBL, SSR, TAA and exposure, supported backends, and limitations
  (no cloud shadows, no path-tracing integration, no space view).
- **Example.** A minimal Swift example that sets a directional light and enables the atmosphere and clouds,
  built and checked against the production API.
- **Checks.** Declared articles exist, have content, changed in this task and are linked; the DocC and
  offline-guide checks run per `.agents/knowledge/user-documentation.md`.

## 12. Facts checked after approval (2026-11-16)

- D1 is confirmed (§4.3): fragment passes into 2D `rgba_16f` targets, with atlases for 3D data.
- Sky ambient (§4.4) moves to a follow-up improvement. Section 4.4 already allowed this outcome.
- SSR gets the sky fallback in stage A, and TAA and path tracing need no change (§4.3). This is a small addition inside the approved scope.
- Article: `Sources/AdaEngine/AdaEngine.docc/Articles/3D/Atmosphere.md`, linked from the Topics list in
  `Sources/AdaEngine/AdaEngine.docc/AdaEngine.md` (the existing `Terrain` article is the precedent).
- Still to do in the plan: per-camera memory accounting for the new tables in `Render3DPerformanceMetrics`, and
  per-backend confirmation of `rgba_16f` render targets and half-float sampling during stage A's first GPU test.

## 13. Stage A outcome and accepted deviations (2026-11-16)

Stage A (atmosphere and aerial perspective) was implemented and reviewed independently twice. This section records
what differs from the approved text above and what the human accepted.

**Performance targets (section 7) are accepted as missed for stage A.** Measured with the existing benchmark on one
desktop Vulkan machine, 1920 by 1080, 400 spheres with sun shadows and eight local lights, best of six rounds:

| Case | Wall ms per frame | Added over `bare` |
| --- | ---: | ---: |
| `bare` | 5.55 | none |
| `+ atmosphere low` | 6.19 | 0.64 |
| `+ atmosphere medium` | 6.29 | 0.74 |
| `+ atmosphere high` | 6.31 | 0.76 |

The targets were under 0.3 ms for `low` and under 0.5 ms for `medium`. The measurement is wall-clock with serialized
passes, because SAGA provides no per-pass GPU timestamps, and its run-to-run noise is about 0.3 ms, so the three
tiers cannot be told apart. The cost is mostly in the composite (the sky reflection blur and the haze lookups), not
in the tables. A camera that does not move under a still sun already redraws no tables, and a camera that only
turns skips the sky-view table. Acceptance criterion 7 is therefore reported as not met, and any later optimization
needs a measurement that can resolve it, for example GPU timestamps or a second machine. Per-camera table memory
is 112.5 KiB (`low`), 554.0 KiB (`medium`) and 808.0 KiB (`high`).

**Implemented as designed after the first review.**

- `Atmosphere3D.tintsSunLight` applies the sun's transmittance to the directional light in the main lighting pass,
  computed on the CPU for the camera's height and the sun's direction. It is skipped in a full-screen debug view.
  Volumetric fog light shafts and the fog's sun glow keep the untinted light.
- Quality tiers differ in table sizes and aerial-perspective slice count as well as in step counts: `low` uses a
  128 by 32 transmittance table, a 96 by 54 sky view and 8 slices of 16 by 16; `medium` 256 by 64, 192 by 108 and
  16 slices of 32 by 32; `high` 256 by 64, 256 by 144 and 24 slices of 32 by 32. The multiple-scattering table is
  32 by 32 in every tier.
- Aerial perspective stores per-channel transmittance in a second atlas, written by the same pass through two color
  attachments, and the sun disc has linear limb darkening (coefficient 0.6, normalized to keep the disc's energy).

**Other deviations, all accepted.**

- An enabled atmosphere replaces the visible sky whatever the skybox settings say, and surfaces that have an
  image-based lighting asset still use it for material lighting and its reflections. The composite pass uses the
  atmosphere for the visible sky and for reflections on surfaces without that asset. Sky ambient light is deferred
  to a follow-up improvement (section 4.4).
- The sun disc is excluded from reflections, and its brightness is 100 times the sun's illuminance before
  `sunDiscIntensity` scales it.
- Stars fade with the sun's elevation and the transmittance of the air in front of them, not with sky luminance.
- The default tier is chosen at compile time (`low` on WebAssembly, `medium` elsewhere), not from the render
  backend at setup, so mobile native builds default to `medium`.
- The atmosphere is not verified with path-traced cameras, and its tables are still built for them.
- Golden frames exist for Vulkan only. The backend-agreement test carries a named allowance,
  `awaitingMetalReferences`, until Metal references are recorded on Apple hardware; browser results are unverified.
  Acceptance criterion 8 is covered by named CI or reported as blocked, never as passed.

## 14. Stage B outcome and deviations (2026-11-16)

Stage B (volumetric clouds) is implemented on Vulkan. This section records where it differs from section 4.5 and section
4.6, and its measured cost is added to section 13 once measured.

- **Compositing.** Clouds are composited over sky pixels only. The planned bilateral, depth-aware upsample is not needed
  for that, because the cloud pass ignores scene depth and the composite uses the full-resolution sky mask. Clouds are
  therefore never drawn over geometry, including very distant geometry, and they are not part of reflections.
- **Noise sizes.** The shape noise is a 64-cubed volume (a 512 by 512 atlas of 8 by 8 slices) and the detail noise is
  32-cubed (a 256 by 128 atlas), not 128-cubed, to keep first-use generation and memory small (about 1.4 MiB for all three
  textures: 1,441,792 bytes). The weather map is 256 by 256. All three are generated on the GPU from the seed with periodic noise, so they tile.
- **Output and history.** The resolve pass writes the same result to a history texture and to a fixed per-view display texture,
  so the composite never reads a texture that depends on a copy of the store taken before the frame began.
- **History.** The temporal blend is a separate resolve pass that reprojects a point in the middle of the layer with the
  previous camera and clamps the history to the 3 by 3 neighbourhood of the fresh sample, with a history weight of 0.9. It restarts on
  the first frame, on a jump of more than 3 km or a turn of more than about 72 degrees, and on a change of tier or size.
  A change of look (coverage, density, type, seed or wind) blends in over a few frames and does not restart the history, and
  the explicit `time` and the wind do not either.
- **Resolution.** `medium` renders a quarter of the pixels and `high` half of the pixels. `low` has no raymarch: it shades one 2D layer
  with the same noise at 40% of the width and height.
- **Camera inside or above the layer.** The march starts at the camera when it is inside the slab, so flying through clouds is
  supported at `medium` and `high`, and from above the layer the march starts at the top sphere. A ray that points at the ground
  draws only the clouds in front of the ground. Each march is capped at 30 km inside the slab, and the
  farthest clouds fade into the horizon with distance.
- **Lighting.** The sun term uses the atmosphere's sun transmittance at the cloud, a dual-lobe phase function with three
  scattering octaves, a powder term and four (`medium`) or six (`high`) light samples. Ambient light is the zenith colour of the sky-view
  table, which is a simplification of the full ambient integral.
- **Cost (section 7 targets not met).** Measured with the same benchmark as section 13, in a later run when the baseline
  frame took 9.18 ms (against 5.55 ms earlier, so the machine was busier), best of six rounds, wall-clock:

  | Case | Wall ms | Added over `+ atmosphere medium` |
  | --- | ---: | ---: |
  | `+ atmosphere medium` | 10.16 | none |
  | `+ clouds low` | 11.72 | 1.56 |
  | `+ clouds medium` | 12.80 | 2.64 |
  | `+ clouds high` | 14.48 | 4.32 |

  The targets were under 0.3 ms for `low` and under 1.0 ms for `medium`, so acceptance criterion 7 is not met for the clouds,
  by a wider margin than for the atmosphere. The wall-clock method and its noise (about 0.3 ms) are the same as in section 13,
  and no per-pass GPU timestamps exist to locate the cost. The likely costs are the light march and the three scattering octaves at every
  cloud sample, the noise fetches, and the resolve pass; they were not profiled.
- **Acceptance criterion 5 (golden frames).** The delivered golden frames are `clouds-noon`, `clouds-low-sun` (medium tier),
  `clouds-low-tier` and `clouds-high-tier`, all at coverage 0.6. Coverage is covered by behavioural tests (monotonic
  coverage of the sky for the medium and low tiers, no clouds at zero coverage) and not by goldens at low, medium and high
  coverage. Ghosting is covered by a GPU test that turns the camera over several frames and compares the result with a settled frame at the
  same pose, not by a pair of golden frames. The human accepts these two substitutions.
- **Seams.** The noise atlases are periodic in z and clamped inside a tile in x and y, so there is a half-texel step at tile
  boundaries (every 9 km for the shape noise, 1.1 km for the detail noise, 40 km for the weather map) that is not visible at the
  resolution the clouds are drawn.
- **Unverified.** Metal and browser results are unverified, and golden frames
  exist for Vulkan only (`clouds-noon`, `clouds-low-sun`, `clouds-low-tier`).
