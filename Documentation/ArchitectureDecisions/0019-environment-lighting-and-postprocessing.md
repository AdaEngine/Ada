# ADR-0019: Environment lighting and postprocessing

- Status: Accepted
- Date: 2026-10-05
- Implementation: Planned

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

- [ ] Manual exposure and HDR bloom with per-camera settings and reusable targets.
- [ ] Local probe assets, influence volumes, selection/blending and Editor authoring.
- [ ] Offline probe capture/baking and lightmap UV/import/material integration.
- [ ] Unified SSR/probe/future-RT reflection composition.
- [ ] HDR/color-space tests, visual controls and GPU/memory budgets.

## Validation requirements

Verify color space, highlight clipping, emission/bloom behavior, exposure
changes and UI stability. Test overlapping probes, absent assets and multiple
cameras. Validate baked lighting on an indoor scene and record bake/runtime costs.

## Consequences

This is an accepted implementation direction, not evidence of shipped behavior.
Each slice must record its tested platform and remaining checklist items.
