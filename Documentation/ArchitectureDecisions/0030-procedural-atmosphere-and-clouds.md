# ADR-0030: Procedural Atmosphere and Volumetric Clouds

Date: 2026-11-16. Status: accepted for the implemented Vulkan path; Metal and browser results are not yet verified.
Scope: [approved design](../Designs/procedural-atmosphere-and-clouds.md) (stage A atmosphere, stage B clouds).

## Decision

Render a physically based sky and a cloud layer as part of `Environment3D`, off by default and pixel-identical when
off.

- **Atmosphere.** Follow Hillaire's table method. Four table passes (transmittance, multiple scattering, sky view,
  aerial perspective) are fullscreen fragment passes into 2D `rgba_16f` targets, with the 3D aerial-perspective volume
  stored as an atlas of slices and its per-channel transmittance in a second atlas written through two color
  attachments. The composite pass reads the tables to draw the sky, the sun disc, stars and distance haze. The
  transmittance and multiple-scattering tables are rebuilt only when the medium changes; the sky-view and
  aerial-perspective tables only when their inputs change, so a still camera under a still sun costs no table work.
- **Clouds.** One curved slab between two spheres around the planet, raymarched at a quarter (`medium`) or half
  (`high`) of the pixels with a per-frame Bayer offset, then blended with the reprojected previous frame (neighbourhood
  clamp) in a resolve pass, and drawn over sky pixels by the composite. The `low` tier has no march: a single shaded 2D
  layer with the same noise, coverage and wind. Noise (Perlin-Worley shape, Worley detail, weather map) is generated on
  the GPU from a `seed` on first use and cached per seed, so no binary asset is added.
- **Tiers.** `low`, `medium` and `high` set table sizes, aerial slice counts and march lengths; the default is `low`
  on WebAssembly and `medium` elsewhere.

## Why fragment passes and not compute

AdaRender uses compute only in fixed-purpose processors, and every other effect, including volumetric fog, is a
fullscreen fragment pass. Fragment passes into 2D targets work on every SAGA backend (Vulkan, Metal and the WebGPU
host) without a new capability, and 3D data is stored as 2D atlases with hand-written trilinear filtering.

## Evidence

Vulkan on Windows: unit tests, a CPU reference for the transmittance integral and the sun transmittance, GPU tests of
the tables against that reference, golden frames for the atmosphere (noon, low sun, night) and clouds (noon, low sun,
low tier), determinism, tiling and history-reset tests, and the existing `Render3DGPUTests` goldens unchanged with the
features off.

## Limits and open items

- The cost targets of the design are not met: about 0.64 and 0.74 ms for `low` and `medium` atmosphere at 1080p on one
  machine, against under 0.3 and 0.5 ms. The benchmark is wall-clock with serialized passes (SAGA has no GPU
  timestamps) and has about 0.3 ms of noise, so the tiers cannot be told apart. See the design, section 13.
- Metal and browser results are unverified, and golden references exist for Vulkan only.
- Clouds are drawn over the sky only, are not part of reflections, do not shadow the ground, and are not verified with
  path-traced cameras. Sky ambient light for surfaces is a follow-up improvement.
- SwiftLint, the editor build and `validate_gpu.sh` could not run on the Windows host used for implementation.
