# Procedural Atmosphere and Volumetric Clouds — Implementation Plan

Design: [procedural-atmosphere-and-clouds.md](../Designs/procedural-atmosphere-and-clouds.md), approved 2026-11-16.
Task: `procedural-atmosphere` (`script/check_contribution.py`).
Branch: `worktree-sky-atmosphere-clouds`.

Two stages, each with full validation and independent review before the next begins. Stage B's file list is
added to the task scope when stage A is closed.

## Stage A: atmosphere and aerial perspective

| # | Step | Files | Check |
| --- | --- | --- | --- |
| A1 | Settings types: `Atmosphere3D`, `AtmosphereQuality3D`, `sanitized`, Codable with `decodeIfPresent`, flat accessors on `Environment3D`, extraction already covered by `ExtractedEnvironment3D` | `CorePipelines/Atmosphere3D.swift`, `CorePipelines/Environment3D.swift` | Red/Green unit tests: defaults, NaN/infinity/range sanitization, Codable round trip, old scene decodes with the feature off (acceptance 1, 2) |
| A2 | CPU reference: Swift implementation of the transmittance and single-scattering integrals, used only by tests | `Tests/AdaEngineTests/Render3DAtmosphereReference.swift` | Known-value tests: zenith and horizon transmittance, Rayleigh phase normalisation |
| A3 | LUT shaders (transmittance, multiple scattering, sky view, aerial-perspective atlas) | `Sources/AdaCorePipelines/Assets/Shaders/atmosphere_common.wgsl` and `atmosphere_{transmittance,multiscatter,skyview,aerial}_3d.wesl` (one fragment entry point per module) | Compiles through SAGACompiler for every backend; shader-source tests as for `volumetric_fog_3d` |
| A4 | `Atmosphere3DViews` resource (per-camera targets, pipelines, uniform cache, retired textures) and `Atmosphere3DRenderNode`, registered after the main pass and before the composite, following `VolumetricFog3DRenderNode` | `CorePipelines/Atmosphere3DResources.swift`, `RenderNodes3D/Atmosphere3DRenderNode.swift`, `Core3DPlugin.swift` | Unit tests: tables update only on change, no work and no texture when disabled or in a replacing debug view, per-view isolation |
| A5 | Composite: sky pixels read the sky-view table, geometry pixels read aerial perspective before height fog, sun disc, star fade; disabled path stays byte-identical | `Assets/Shaders/environment_composite.wesl`, composite uniform code | GPU golden frames: sun at noon, 10 degrees, below horizon; no horizon seam (acceptance 3, 4); existing goldens unchanged (acceptance 1) |
| A6 | SSR miss samples the sky-view table when the atmosphere is on | `RenderNodes3D/ScreenSpaceReflectionRenderNode.swift`, `Assets/Shaders/screen_space_reflection.wesl` | GPU test: reflection of the sky matches the displayed sky within tolerance |
| A7 | Metrics: per-pass timing and per-camera table memory in `Render3DPerformanceMetrics`; benchmark case for each tier | `CorePipelines/Render3DPerformanceMetrics.swift`, benchmark suite | Numbers against design §7 (acceptance 7) |
| A8 | Article and navigation | `Sources/AdaEngine/AdaEngine.docc/Articles/3D/Atmosphere.md`, `Sources/AdaEngine/AdaEngine.docc/AdaEngine.md` | Runner `documentation` check; example compiles against the production API |
| A9 | Full validation and independent review | — | `check_contribution.py run --stage review`, `script/validate_gpu.sh`, separate-context review |

## Stage B: volumetric clouds (scope added after stage A closes)

| # | Step | Files (planned) | Check |
| --- | --- | --- | --- |
| B1 | `VolumetricClouds3D` settings and sanitization | `CorePipelines/VolumetricClouds3D.swift`, `Environment3D.swift` | Unit tests as A1 |
| B2 | Procedural noise atlases from `seed`, generated on first use | `Assets/Shaders/clouds_noise.wesl`, resource code | Determinism test: same seed, same pixels |
| B3 | Raymarch at reduced resolution, Bayer offset, history reprojection with neighbourhood clamp, depth-aware upsample | `Assets/Shaders/clouds_3d.wesl`, `RenderNodes3D/Clouds3DRenderNode.swift` | Golden frames with explicit `time`; two-frame ghosting test; camera-cut reset (acceptance 5, 6) |
| B4 | `low` tier 2D layer | `clouds_3d.wesl` | Golden frame on the browser tier settings |
| B5 | Benchmark, article update, validation, review | docs, tests | Acceptance 7 to 9 |

## Implementation choices within the design

- Fragment passes into 2D `rgba_16f` targets, with atlases for 3D data (design D1, verified).
- The atmosphere is a separate render node, not a branch inside the fog node, so each effect keeps its own timing
  and its own per-camera resources.
- The disabled path performs no work: no node submission, no textures, no uniform writes. The composite shader
  receives a flag, and its disabled branch is unchanged so existing goldens hold.
- Sun direction comes from `ExtractedLighting3D.directionalLight`, the same source as volumetric fog.
- Default tier is `medium` on desktop and `low` on browser and mobile, chosen from the render backend at setup.

## Validation commands

- `swift test --filter Render3DAtmosphere` (unit and reference tests; GPU suites nested under `Render3DGPUTests`).
- `script/validate_gpu.sh` for golden frames on the available native backend.
- `ADAENGINE_PERF=1 ADAENGINE_GOLDEN_SAGA=1 swift test -c release -Xswiftc -enable-testing --filter Render3DGPUTests/Benchmarks`.
- `python script/check_contribution.py run --task procedural-atmosphere --stage review`.
- If the shared `.build` has a toolchain mismatch, use an isolated `--scratch-path`, per `AGENTS.md`.

## Blocked until proven available

Browser-host golden frames and any backend not present on this machine are reported as blocked or covered by named
CI, never as passed.

## Decisions after independent review (2026-11-16)

The independent review found three deviations between the code and the approved design. The human chose to implement the
design as written in each case:

- `Atmosphere3D.tintsSunLight` is implemented. `Atmosphere3DMath.sunTransmittance` integrates the sun's transmittance
  on the CPU for the camera's height and the sun's direction, and the main lighting pass multiplies the directional
  light's radiance by it when the setting is on. Volumetric fog light shafts and the fog's sun glow keep the untinted
  light.
- Quality tiers differ in table sizes and aerial-perspective slice count as well as in step counts: `low` uses a
  128 by 32 transmittance table, a 96 by 54 sky view and 8 slices of 16 by 16; `medium` 256 by 64, 192 by 108 and
  16 slices of 32 by 32; `high` 256 by 64, 256 by 144 and 24 slices of 32 by 32. The multiple-scattering table stays
  32 by 32. Per-camera memory is 112.5, 554.0 and 808.0 KiB, because aerial perspective now stores a second
  atlas.
- Aerial perspective stores per-channel transmittance in a second atlas, written by the same pass through two color
  attachments, and the sun disc has linear limb darkening (coefficient 0.6, normalized to keep the disc's energy).
