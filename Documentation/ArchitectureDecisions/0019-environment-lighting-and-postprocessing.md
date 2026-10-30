# ADR-0019: Environment lighting and postprocessing

- Status: Accepted
- Date: 2026-10-05
- Implementation: Partial (exposure/bloom, baked GI and dynamic local-light probe relighting implemented locally; not released)

## Context

The renderer uses offline-baked irradiance/specular/BRDF maps, SSR and an
existing tone mapper. It lacks local reflection probes, a general baked indirect
lighting path, bloom and author-controlled exposure.

## Decision

Extend Environment3D with compatible optional exposure and bloom settings.
Keep scene color linear HDR until the final tone-map/output transform. Bloom
extracts HDR energy and uses a reusable downsample/upsample chain before tone
mapping. UI stays outside exposure and bloom.

Add authored local reflection probes with bounded selection/blending and an
IBL fallback. Offline capture/baking is the first probe implementation; runtime
recapture is separately budgeted. Add baked indirect lighting/lightmaps with
explicit UV and asset contracts. SSR/RT reflections supplement probe lighting
through one compositing contract rather than double-counting specular energy.
Dynamic global illumination remains a later decision driven by scene needs.

## Implementation checklist

- [x] Manual exposure and HDR bloom with per-camera settings and reusable targets (Metal; recorded in ADR-0027 Stage 1).
- [ ] Local probe assets, influence volumes, selection/blending and Editor authoring.
- [x] Baked diffuse transport, lightmap UV1/import/material integration and regular spatial irradiance probes with visibility (2026-10-30; see delivery below).
- [ ] Complete offline reflection-probe capture/baking workflow and Editor authoring.
- [ ] Unified SSR/probe/future-RT reflection composition.
- [ ] HDR/color-space tests, visual controls and GPU/memory budgets.

## Validation requirements

### Baked diffuse GI delivery, 2026-10-30

The new path bakes linear HDR irradiance/pi into non-directional lightmaps and
a regular L2 SH grid with octahedral distance moments. Derived static GLBs own
padded UV1 charts; imported instances bind independent material copies.
Direct analytic lights and specular IBL remain runtime contributions. Baked
diffuse replaces ambient diffuse without duplicate material AO and enters the
HDR scene before exposure/bloom. This does not complete the local reflection
probe/Editor or unified reflection composition checklist items above.

The Last Autumn corridor has two fixed day/night states, 39 lightmaps and
1485 probes (1312 valid) per state, using 13.87 MiB HDR texture data each.
26 focused WebGPU/renderer-history tests, four offline transport tests and
three game-side asset/provenance/relocation tests pass. Native day/night,
reconstruction and state-change controls are recorded in the game's
`Evidence/BakedGI`; update cadence is not GPU-time or performance acceptance.
Apple hardware acceptance remains open. The previous full golden-suite
exception in ADR-0027 remains separate; reference images were not changed.

No adaptive placement, runtime probe updates, directional surface maps or
dynamic off-screen GI is claimed. Source radiance uses triangle-centre
approximations and visibility has finite angular resolution. See
[BakedGI](../BakedGI.md) and [ADR-0027](0027-3d-rendering-pipeline-gap-roadmap.md)
for API, reproduction, limitations and remaining work.

Optional GPU relighting now updates these probes from moving point/spot lights
using cached static surface paths and current light-volume shadows, including
sources and bounce surfaces outside the camera view. This is one dynamic
diffuse bounce with a bounded update schedule; geometry paths remain static.
See [DynamicGI](../DynamicGI.md) and ADR-0027's dated follow-up.

### General requirements

Verify color space, highlight clipping, emission/bloom behavior, exposure
changes and UI stability. Test overlapping probes, absent assets and multiple
cameras. Validate baked lighting on an indoor scene and record bake/runtime costs.

## Consequences

This is an accepted implementation direction, not evidence of shipped behavior.
Each slice must record its tested platform and remaining checklist items.
