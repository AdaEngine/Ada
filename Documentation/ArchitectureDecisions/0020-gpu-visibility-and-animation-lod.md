# ADR-0020: GPU visibility and animation LOD

- Status: Accepted
- Date: 2026-10-05
- Implementation: Implemented on Metal with CPU fallback; WebGPU GPU compaction remains a backend extension

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

- [x] Hi-Z generation, conservative bounds tests and disocclusion recovery.
- [x] Backend-neutral indirect draw/compaction capability and Metal implementation.
- [x] Skinned mesh LOD asset/runtime contracts.
- [x] Animation evaluation cadence, interpolation and significance policies.
- [x] Large-scene CPU/GPU profiling with correctness comparison to CPU reference.

## Validation requirements

Compare visibility with CPU reference in moving-camera, moving-object and
occluder-removal scenes. Verify offscreen shadow casters and independent cameras.
Measure draw/triangle counts separately from actual GPU and CPU time. Validate
character transitions, animated bounds and gameplay independence.

## Recorded implementation

The first GPU path uses current-frame opaque/alpha-mask depth and max-depth
Hi-Z, followed by per-draw instance compaction and indexed indirect arguments.
This avoids stale-depth disocclusion errors and keeps shadow lists independent.
Metal executes this path; other backends retain CPU visibility. Character mesh
LODs preserve the ordered palette and material contracts. Projected-size
animation cadence interpolates visible poses while playback/gameplay clocks
remain independent. See [PerformanceValidation.md](../../Demos/SkeletalGarden/PerformanceValidation.md)
for concrete tests, measurements, opt-in controls and platform limits.

## Consequences

This is an accepted implementation direction, not evidence of shipped behavior.
Each slice must record its tested platform and remaining checklist items.
