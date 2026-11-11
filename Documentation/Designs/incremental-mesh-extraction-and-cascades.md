# Incremental mesh extraction and directional cascades

Status: Proposed for human approval.
Date: 2026-11-10.
Classification: Internal improvement to existing 3D extraction and shadow preparation.
Extends [Pipelined Rendering](pipelined-rendering.md) and [GPU-Driven Shadow Batching](gpu-driven-shadow-batching.md).

## Workload and outcome

The standalone Bevy City port creates 45,700 mesh entities, including 1,327 moving cars. On Windows with an
RTX 4070 and Dawn D3D12 at 1920×1080, the current renderer spends roughly 57–69 ms in render-world extraction
and 97–107 ms in the directional shadow node. Turning off all shadows reduced one measured frame average
from 204 ms to 100 ms. Those node timings are CPU wall-clock measurements. The GPU timestamp probe could not
produce valid samples on the tested Dawn build.

Keep the existing render and asset contracts. Reduce steady-state work for unchanged mesh sources and reuse
their shadow preparation. Preserve the city's geometry, traffic, LOD selection, distance limits, frustum culling,
contact shadows, cascade configuration, and rendering resolution in the acceptance benchmark.

## Incremental extraction

- Keep the current full extractor as the bootstrap and correctness reference. Feed the incremental path from
  an opt-in, bounded ECS change stream scoped to the component types used by mesh extraction. Use existing
  mutation and change-detection boundaries so typed writes, direct writes, runtime writes, component removal,
  entity lifecycle, and deferred commands all produce equivalent notifications. Register observers before the
  initial snapshot. Coalesce multiple updates by entity and resolve the current components at extraction time.
- Each render world owns its cursor and acknowledges a batch only after consuming it. A world replacement,
  missed history, unsupported writer, or failed reconciliation forces a full rebuild. Use a synchronized
  publication boundary for concurrent writers and preserve the established pipelined frame isolation.
- Retain extracted records by source identity, including the distinction between individual and instanced
  meshes. Update only affected records and membership. A change in inherited visibility or path tracing role
  invalidates affected descendants. Handle current and previous transforms separately so motion vectors settle
  when an object stops. Keep any work that depends on current animation or material time on a conservative
  dynamic path.
- Track mutable shared PBR materials separately from ECS component changes. Check each live material's revision
  once and refresh its dependent snapshots only when needed. Keep existing behavior for custom or untracked
  state with a conservative fallback. Publish render-owned data at extraction and keep the previous frame's
  resources valid through their established lifetimes.

## Directional shadow preparation

- Use the extracted source changes to maintain the caster registry and reusable per-source shadow data.
  Retain eligible geometry pools and batch state across frames. Update membership, bounds, draw keys, and
  instance data when their inputs change. Continue to use the existing GPU culling and batching path on supported
  WebGPU devices.
- Keep reusable caster membership and batch data for each CPU cascade. Key reuse on the effective cascade
  frustum and the camera and settings used for LOD and distance evaluation. For an unchanged view, update
  affected membership and rebuild or upload only affected batches. Preserve current draw ordering where it
  affects output. Instance storage and any GPU updates must respect frames in flight.
- Re-evaluate camera-dependent visibility when the camera or cascade changes. Reuse view-independent caster
  preparation across cascades and frames, including during camera motion. Share camera-dependent LOD results
  across passes only where the inputs and hysteresis behavior are equivalent.
- Invalidate affected entries when a caster enters or leaves a cascade, changes its bounds, selects another LOD,
  fades out, or changes shadow material or eligibility. View, light, atlas, and backend changes invalidate the
  matching retained data. Preserve the full preparation path for unsupported casters or invalidation cases
  without a reliable incremental representation. Retain current shadow-map rendering cadence.

## Scope and alternatives

The work belongs in AdaECS change detection, AdaScene mesh extraction, and AdaCorePipelines shadow preparation.
Keep backend-neutral correctness and the existing WebGPU GPU path and native Metal and headless CPU paths.
Local-light shadow reuse remains under its existing contract. A per-frame scan of change ticks would preserve
behavior but still visit the entire scene. Porting Bevy's GPU LOD selection, adding GPU support to other
backends, caching shadow pixels, and lowering quality or update rate are outside this increment.

## Acceptance and evidence

- Use the real extraction path to cover static, sparse-change, and structural frames. Include spawn, despawn,
  component removal, same-frame replacement, shared material edits, hierarchy visibility, animated and
  instanced sources, motion settling, and skipped-frame recovery. Verify the resulting render snapshot against
  a full rebuild in serial and pipelined modes.
- Extend the existing visibility and shadow tests. Compare incremental and full-preparation output for fixed
  and moving cameras, moving casters crossing cascade or LOD boundaries, light and atlas changes, and camera
  removal. Exercise the WebGPU CPU and GPU shadow paths and the supported fallback paths. Run the repository
  WebGPU validation and retain rendered comparisons.
- Record counts of sources examined and updated, shadow candidates rebuilt, and instance data rewritten.
  After warmup, verify that unchanged ordinary sources avoid per-entity extraction work and that a fixed
  cascade with sparse caster changes retains unaffected batches. Report conservative fallback coverage and
  memory overhead.
- Build the existing standalone city against both the baseline and the candidate with the same Release
  toolchain and dependency configuration. Run the fixed and orbiting camera modes at verified 1920×1080
  on the same Windows RTX 4070 through Dawn D3D12. Keep seed 42, 30×30 blocks, 5% car density with traffic
  moving, frustum culling, LOD, contact shadows, and the same effective three 2048-pixel cascades and
  shadow distance. Use the existing warmup and at least 15 seconds of sampling per run. Alternate baseline
  and candidate in repeated runs and retain JSON, screenshots, frame-time ranges, p95, and a separate set
  of extraction and shadow phase timings. Judge improvement against observed run-to-run variation.
- User documentation is inapplicable to this internal optimization because it preserves authoring,
  configuration, and rendering behavior. Review that rationale and verify the unchanged standalone
  example using the Windows benchmark. Publish benchmark evidence with the change.
