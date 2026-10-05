# ADR-0018: Local lights and shadow scheduling

- Status: Accepted
- Date: 2026-10-05
- Implementation: Planned

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

- [ ] Multiple directional/point/spot extraction, GPU uniforms and PBR evaluation.
- [ ] Finite range, attenuation and spot-cone API with scene coding and Editor controls.
- [ ] Point/spot shadow resources, allocation budget and scheduling.
- [ ] Animated/alpha-masked shadows and independent caster visibility.
- [ ] Native lighting/shadow captures and performance measurements for many lights.

## Validation requirements

Test light transforms, cutoff/attenuation, zero intensity and per-camera
isolation. Compare illuminated surfaces against a no-light control and verify
shadowed/unshadowed cases, moving casters, atlas exhaustion and light removal.
Record actual GPU cost and limits; component registration is not rendering proof.

## Consequences

This is an accepted implementation direction, not evidence of shipped behavior.
Each slice must record its tested platform and remaining checklist items.
