# ADR-0018: Local lights and shadow scheduling

- Status: Accepted
- Date: 2026-10-05
- Implementation: Partial (local foundation; not released)

## Implementation status

Last verified: 2026-10-05 in the current checkout. This implementation is local
and uncommitted. Four directional and 32 per-camera local lights use bounded
forward PBR lighting. Range attenuation and spot half-angles are explicit, with
legacy point/spot payload decoding and Inspector fields.

Each camera owns a reusable atlas: 512-pixel tiles, six columns, up to four light
slots/rows. Point lights render six faces and spot lights one in a single atlas
pass. Priority and estimated influence select winners; retained winners keep
slots. Over-budget sources retain unshadowed lighting. Alpha-mask, GPU skinning
and independent caster culling reuse the existing shadow path. Local uniforms,
shadow matrices and IBL inverse-view constants use independent per-camera rings.

Native Metal controls cover no-local-light, point-only, spot-only, unshadowed,
budget, many-light, moving and multi-camera scenes. Results and limits are in
[LocalLightingValidation.md](../../Demos/SkeletalGarden/LocalLightingValidation.md).
Apple mobile/WebGPU execution and visual Inspector interaction remain unverified.
Clustered light assignment, contact-quality refinement and adaptive atlas tile
sizes remain future work. Transparent BLEND materials do not cast shadows.

## Context

PointLightComponent and SpotLightComponent exist, but the current lighting
extraction/shader path consumes one primary directional light. Complete local
lighting is a prerequisite for indoor scenes and emissive-looking light sources
that actually illuminate nearby geometry.

## Decision

Extract visible directional, point and spot lights into bounded per-view GPU
light lists. Define linear radiance, distance attenuation, range and inner/outer
spot-cone semantics consistently with PBR. Preserve one sunlight as the primary
cascaded-shadow source. Start with bounded forward lighting; introduce clustered
light assignment when profiling justifies it.

Add optional point/spot shadow maps with a bounded atlas/cubemap budget, explicit
priority and stable allocation. Shadow visibility remains independent from the
camera's visible mesh list. Support alpha-masked and animated casters. Unshadowed
lighting remains available when the budget is exhausted or a backend lacks a
required feature. Avoid a pass or allocation per light every frame.

## Implementation checklist

- [x] Multiple directional/point/spot extraction, GPU uniforms and PBR evaluation.
- [x] Finite range, attenuation and spot-cone API with scene coding and Editor controls.
- [x] Point/spot shadow resources, allocation budget and scheduling.
- [x] Animated/alpha-masked shadows and independent caster visibility.
- [x] Native lighting/shadow captures and performance measurements for many lights.

## Validation requirements

Test light transforms, cutoff/attenuation, zero intensity and per-camera
isolation. Compare illuminated surfaces against a no-light control and verify
shadowed/unshadowed cases, moving casters, atlas exhaustion and light removal.
Record actual GPU cost and limits; component registration is not rendering proof.

## Recorded backend validation

SkeletalGarden now enables local lights in ordinary launches; `--daylight`
restores the original sunlight scene. macOS Metal and native WebGPU captures,
plus a Swift 6.3.2 WASM debug export running in the Codex in-app browser, exercise
colored point/spot illumination and atlas shadows. Browser controls verify light
and shadow toggles. See [WebGPUValidation.md](../../Demos/SkeletalGarden/WebGPUValidation.md)
for the build commands, proof boundaries and backend compatibility fixes.

## Consequences

This is an accepted implementation direction, not evidence of shipped behavior.
Each slice must record its tested platform and remaining checklist items.
