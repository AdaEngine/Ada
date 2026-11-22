# Studio shadow map cache

- Status: proposed for human approval
- Scope: internal improvement to the macOS Ada Studio 3D edit viewport
- Related design: [Incremental mesh extraction and directional cascades](incremental-mesh-extraction-and-cascades.md)
- Existing contract: [Local lights and shadow scheduling](../ArchitectureDecisions/0018-local-lights-and-shadow-scheduling.md)
- Local evidence: `.build-tools/studio-interactions/studio-render-experiments/REPORT.md`

## Outcome

Reuse rendered shadow data for static geometry while the scene continues to animate. Moving robots must cast shadows from the pose used for the same rendered scene frame. Camera motion must use shadow maps and matrices that match the updated view. Preserve the configured shadow resolution, filtering, light selection, and viewport rendering cadence.

Skeletal Garden spends about 27 ms of GPU time on directional and local shadows during hierarchy scrolling. Holding both maps demonstrated the cost of regenerating them, while leaving the robots' shadows stale. The directional path already retains caster preparation but clears and draws the map again. The local path already reuses complete faces when their contents match. In the control it redrew a median of seven faces and reused six.

## Cache policy

- Enable the cache internally for the macOS Metal edit viewport. Keep the current render path available as the correctness reference and fallback. Play mode, game windows, and other backends retain their current rendering path. The window/scene submission order stays fixed across the cache benchmark.
- Track rendered static shadow data per camera and directional cascade or local-light atlas face. Use the existing caster selection, draw lists, and face reuse to retain their culling, LOD, and alpha-test behavior. An existing local face that is fully clean stays on its current fast path.
- Keep a caster in the dynamic draw set when its output depends on skinning, morph targets, time, or an input whose changes cannot be tracked reliably. Changes to an otherwise cacheable caster update its affected static regions. Use both old and new bounds for movement and removal. An unbounded change invalidates the affected view or uses its full draw path.
- Re-evaluate a tile when its effective light-space projection, atlas allocation, light assignment, or shadow settings change. Membership, visibility, LOD, fade, and alpha-affecting material or texture changes also invalidate affected static data. Directional camera motion re-evaluates effective cascade projections and camera-dependent selection. Local lights retain valid faces when the active light, slot, projection, and relevant caster selection still match. A face skipped by receiver culling must be valid or regenerated before it can be sampled again.
- Draw cached static casters into a separate color atlas, with shared depth scratch for rasterization. Render the current dynamic casters for affected tiles into scratch using the same projection and tests. Compose the nearest stored depth at each texel into the existing shadow output before lighting samples it. The existing shadow shader stores normalized fragment depth with 1.0 as the cleared value. A texel-wise minimum preserves the result before any filtering. Leave a clean output tile alone when neither layer changed. Recompose from the static layer after its last dynamic caster leaves.
- The render world owns the cache and uses the established render order and GPU resource retention for writes and reads. Keep at most one additional persistent color atlas per cached output and reuse compatible transient color and depth scratch within the render world. Retire cache entries with their authoritative view or atlas. Rebuild after an allocation change or invalid GPU work. Use the full draw path for incompatible layouts, unproven caster state, or when the additional textures cannot be provisioned within the renderer's supported limits.

Comparison with the full draw path is part of the design. Holding a finished map on a timer can improve cadence while showing old robot shadows. Reducing shadow resolution changes quality and would measure a different optimization. Keeping the combined output preserves the existing lighting consumers and applies filtering once to the composed depth data.

## Acceptance checks

1. Add focused renderer regressions for a fixed camera and static geometry with animated casters, camera motion across cascade changes, and a local caster entering or leaving a face. Cover transforms, removal, light or atlas reassignment, and view lifetime. Render matched cached and full-path frames at the same animation poses and camera states. After a pose, camera, or light change, the first preview frame rendered with that state must use its current shadows. Compare shadow output as well as the composed scene to expose stale silhouettes and disocclusion.
2. Run the existing native SAGA GPU validation on macOS, including fresh WESL compilation and the Metal golden suites. Validate the unaffected platform path with the repository's applicable checks. Keep the fallback selectable for the reference rendering and for unsupported conditions.
3. On the same M3 Pro, alternate at least three Release pairs at the existing 1728 × 1084 pt Skeletal Garden layout. Reuse the two-second hierarchy and Inspector wheel gestures with both robots animated. Add a repeatable viewport camera move with the same initial pose and traveled path in each mode. Record GPU time for directional shadows, local shadows, and composition, the panel p95 during scrolling, and the visible viewport p95 and update count during the camera move. Retain captures, frame IDs, and peak cache allocation. Judge gains against repetition variability and report scroll and motion independently.
4. Ship the optimization only with current shadows and a repeatable reduction in shadow GPU cost for the target workload. Show any motion-path or panel-p95 tradeoff alongside the gain. A redraw on a genuine invalidation is valid. An old shadow on a newer rendered pose or view is a failure.

This is an internal-only improvement. It adds no user setting and preserves scene authoring and shadow behavior. The review will verify that rationale and the rendered Skeletal Garden checks.
