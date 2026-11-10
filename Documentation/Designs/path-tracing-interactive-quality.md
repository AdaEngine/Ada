# Interactive path tracing: performance and reduced-resolution quality

Status: **proposal, awaiting approval**. Scope: the portable shader path tracer
(`PathTracing3DRenderNode`, `path_tracing_3d.glsl`). Hardware ray tracing, the
131,072-triangle scene cap and the material atlas are out of scope here.

## Problem

Measured on Sponza (RTX 4070, WebGPU/D3D12, 952×447 rays, 1 spp, 2 interactions):
~28 FPS with 0–12 local lights, independent of light count within noise
([SponzaLightingPerformance](../Performance/SponzaLightingPerformance-2026-11-03.md)).
At the interactive half-resolution preset the image looks soft and noisy, and any
camera motion discards all history.

Code inspection shows where the time and the quality go:

1. **Every light, every bounce.** `directLight` enumerates all lights and traces a
   shadow ray to each. With the sun and 12 local lights, 2 interactions cost
   2 path rays + 26 shadow rays per pixel per frame.
2. **Primary rays repeat raster work.** The first hit is traced through the BVH
   although the raster G-buffer (normals, positions) for the same view is bound.
3. **No reprojection.** The history digest includes the view matrix, so motion
   restarts accumulation at one noisy sample.
4. **Fixed upsampling.** Reconstruction is a 2×2 geometry-weighted filter of the
   half-resolution result; sub-pixel detail cannot recover over time.
5. **Per-frame GPU allocation.** The light table texture is created every frame.

## Proposal

| # | Change | Expected effect | Trade-off |
| --- | --- | --- | --- |
| A | Reuse the light table texture; rewrite it only when lights change | Removes a per-frame allocation (spike source) | None |
| B | Sample one light per bounce (power/distance-weighted, plus the sun) instead of all lights | Shadow rays per pixel drop from 26 to ~4 at 12 lights | More per-frame noise, absorbed by B+C accumulation |
| C | Temporal reprojection: reproject history through the G-buffer position, reject by depth/normal, clamp to a neighborhood | History survives camera motion; motion no longer resets to 1 spp | Ghosting must be bounded; adds one pass |
| D | Temporal upsampling: jittered sub-pixel ray origins accumulated at output resolution (TAAU-style) | Half-resolution rays converge toward full-resolution detail | Needs C; first frames after disocclusion stay soft |
| E | Hybrid first hit from the G-buffer (needs hit material id/albedo in the G-buffer) | Saves the primary traversal | G-buffer format change; largest change, optional |

Recommended order: A (bug-level, no visual change) → B → C → D; E only if
measurements still show primary traversal dominating.

## Validation

- GPU tests (WebGPU and Metal): history survives a small camera move; disocclusion
  rejects stale history; light-table texture identity is stable while lights are
  static; deterministic output with a fixed seed.
- Opt-in Sponza benchmark: frame time and static/moving convergence images at
  quarter and half resolution, before/after each step, same machine and route.
- User guide: the path-tracing settings article documents the new behavior and
  any new settings (e.g. light samples per bounce).

## Decisions needed

1. Approve B (stochastic light sampling) as the default, or keep exhaustive
   lighting as an option (`lightSamplesPerBounce = 0` meaning "all")?
2. Approve C+D (temporal reprojection and upsampling) as the interactive default?
3. Include E (G-buffer change) now, or defer?
