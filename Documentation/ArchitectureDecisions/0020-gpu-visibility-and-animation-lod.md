# ADR-0020: GPU visibility and animation LOD

- Status: Accepted
- Date: 2026-10-05
- Implementation: Planned

## Context

The renderer already batches/instances meshes and uses CPU frustum lists,
independent shadow-cascade visibility, static LOD and distance fading. It does
not yet use GPU Hi-Z occlusion, GPU-generated indirect draws, character mesh LOD
or reduced animation evaluation rates.

## Decision

Keep CPU visibility as the reference and fallback. Add conservative Hi-Z
occlusion from scene depth, with explicit previous-frame/disocclusion handling,
and GPU compaction/indirect submission where backend capabilities allow it.
Keep camera and shadow-caster decisions separate. Newly visible or moved objects
must not disappear because of stale depth.

Extend LOD to skinned characters with compatible skeleton/palette/material
contracts. Schedule animation evaluation by projected significance and distance;
retain gameplay/root transforms and interpolate render poses between evaluations.
Use hysteresis to prevent mesh and update-rate oscillation. Keep collision and
gameplay simulation independent from visual LOD.

## Implementation checklist

- [ ] Hi-Z generation, conservative bounds tests and disocclusion recovery.
- [ ] Backend-neutral indirect draw/compaction capability and Metal implementation.
- [ ] Skinned mesh LOD asset/runtime contracts.
- [ ] Animation evaluation cadence, interpolation and significance policies.
- [ ] Large-scene CPU/GPU profiling with correctness comparison to CPU reference.

## Validation requirements

Compare visibility with CPU reference in moving-camera, moving-object and
occluder-removal scenes. Verify offscreen shadow casters and independent cameras.
Measure draw/triangle counts separately from actual GPU and CPU time. Validate
character transitions, animated bounds and gameplay independence.

## Consequences

This is an accepted implementation direction, not evidence of shipped behavior.
Each slice must record its tested platform and remaining checklist items.
