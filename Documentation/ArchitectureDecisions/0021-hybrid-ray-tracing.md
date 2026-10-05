# ADR-0021: Hybrid ray tracing

- Status: Accepted
- Date: 2026-10-05
- Implementation: Planned

## Context

AdaRender currently has no ray-tracing acceleration structures or RT passes.
The raster path provides PBR, IBL/SSR and shadow maps. Full path tracing is not a
prerequisite for the next renderer milestone.

## Decision

Introduce optional backend-neutral acceleration-structure and ray-dispatch
capabilities, implemented first by Metal. Detect device support at runtime and
retain the complete raster fallback. Cache bottom-level mesh structures and
maintain a per-world top-level instance structure; distinguish build/refit and
budget changes to static, rigid and deformed geometry.

The first visual feature is hybrid RT reflections integrated with the existing
SSR/IBL composition. Define hit shading/material access, alpha-mask handling,
roughness/ray budgets, temporal accumulation and denoising explicitly. Reuse the
motion/depth/history foundation from ADR-0017. Unsupported or over-budget paths
fall back to SSR/probes/IBL without losing the scene.

Evaluate RT shadows and indirect lighting after reflection correctness and cost
are established. Full path tracing, frame interpolation and MetalFX denoised
upscaling are separate future slices, not implied by initial RT support.

## Implementation checklist

- [ ] Runtime capabilities and backend-neutral acceleration/ray APIs.
- [ ] BLAS cache, TLAS instance lifetime and rigid/deformed geometry update policy.
- [ ] RT reflection dispatch, material hit shading and raster fallback composition.
- [ ] Temporal accumulation/denoising and per-camera history reset.
- [ ] Metal reflection correctness, capability fallback and GPU/memory measurements.
- [ ] Subsequent RT shadows/GI evaluation with separate acceptance criteria.

## Validation requirements

Test transformed/removed instances, animated geometry, masked materials,
independent cameras and unsupported devices. Capture reflections of offscreen
geometry and compare SSR/IBL/RT controls. Record acceleration build/refit,
ray/denoising costs and memory on actual hardware.

Reference: [Apple Metal ray tracing](https://developer.apple.com/videos/play/wwdc2023/10106/).

## Consequences

This is an accepted implementation direction, not evidence of shipped behavior.
Each slice must record its tested platform and remaining checklist items.
