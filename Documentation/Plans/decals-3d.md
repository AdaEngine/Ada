# 3D decals implementation plan

The [approved design](../Designs/decals-3d.md) covers decals placed from
Swift on opaque static, rigid, and skinned mesh entities. The first release
includes placement in the character's current pose.

## 1. Prove surface tracking and PBR integration

- Start with a small headless render fixture based on the existing two-joint
  ribbon model. Apply a patterned stamp across its bend while the ribbon
  is bent. Capture the bent, straight, and bent-again frames. Track features
  in the stamp against reference points on the original triangles.
- Use `Mesh.Part.meshDescriptor` for source triangles and
  `SkinnedMesh3DComponent` for the mesh-local joint palette. For the initial
  projection, compare the evaluated triangle positions with the render
  path. Where morphing is active, use the renderer's target selection and
  apply morphs before skinning. For subsequent animation, evaluate the
  source corners, then interpolate their positions with the stored
  barycentric weights. This keeps shared triangle edges aligned.
- Prototype the clipped patch and prove that its coverage can modify
  `AdaPBRSurface` before lighting in `flat3d.wesl`. Evaluate receiver-local
  coverage indexed by stable mesh geometry first. If a view-local coverage
  pass is needed, verify receiver and depth matching where two meshes
  overlap. Check the shader bindings, target formats, and render graph cost
  on Vulkan and Metal before fixing the representation. Record the chosen
  path and costs in this plan. Return any change to the accepted behavior
  or backend scope for approval.

## 2. Deliver placement on walls and moving meshes

- Add the Swift placement, appearance update, and removal entry points in
  `AdaScene`. Key state by the receiving mesh entity, optional part, and
  decal handle. Validate the receiver, projector transform and dimensions,
  material, and the generated footprint before publishing a decal. Report
  empty intersections and unsupported geometry through the placement result.
  Use the render mesh for this decision even when a physics hit supplied
  the initial position and normal.
- Clip the projection to the selected mesh in receiver-local coordinates.
  Use the published world transform for placement, then let existing
  transform propagation carry the decal with its receiver, including
  child meshes on a physics-driven parent. Feed state through
  `ExtractModel3D` and `Model3DExtractionCache` into the existing draw
  pipeline. Preserve receiver identity through visibility and batching
  so two entities sharing a mesh and material keep independent decals.
- Test a wall and two identical cars. Place one decal at setup and another
  after the target car moves. Verify the expected local placement while the
  car turns, with an occluder present, and from a grazing view. Cover
  projection depths, facing cutoff, an out-of-range mesh part, and a
  physics hit that misses the render geometry. The other car and the wall
  retain their own appearances.

## 3. Deliver placement in the current animated pose

- Resolve new skinned placement requests against the evaluated pose and
  propagated transform that extraction observes. Specify when the API
  resolves a placement request so callers can distinguish an accepted
  request from a successful stamp. Use the renderer's current skin and
  morph inputs. Build and store the clipped footprint at placement, then
  reuse it as the pose changes. Support imported models with shared or
  mirrored material UVs.
- Keep compatible source topology selected while a skinned attachment
  survives. Verify the regular mesh LOD selection in `VisibleMesh3DLists`
  and any index substitution used by the chosen draw path. Release the
  constraint with the final decal. Replacing the mesh or destroying the
  receiver invalidates its handles and retires render resources using the
  existing submission lifetime. Hiding a receiver preserves its decals
  for when it becomes visible again.
- Add production-path tests for stamping on the bent ribbon, then
  straightening it, for combined morph and skin, and for an independent
  copy of the same model. Test the LOD transition before and after removal,
  and check that motion and occlusion remain tied to the receiver.

## 4. Finish material blending and measure

- Blend base color using texture alpha. Apply optional normal and
  roughness in the same PBR surface path, with normals converted to the
  receiver's shading space. Test partial coverage, zero coverage,
  individual appearance updates, and overlaps ordered by priority and
  creation order. Preserve the receiver's depth, silhouette, and shadow
  geometry. Compare decal-free draw output against existing references.
- Measure CPU placement time, frame time on the CPU and GPU where
  instrumentation is available, and allocated memory. Compare matched
  runs with zero decals, steady attached decals at increasing counts,
  and repeated placement and removal. Include both rigid and animated
  receivers and record hardware, resolution, counts, and toolchain.
  Use the results to set and test placement and storage limits and
  document behavior when a limit is reached.

## 5. Validate, document, and review

- Use a focused Swift Testing suite `Decal3DPlacementTests` in
  `AdaSceneTests` for projection, attachment, and lifetime. Run
  `swift test --filter Decal3DPlacementTests` through the contribution
  runner to record behavioral Red, Green, and Refactor. Put render
  comparisons under `Render3DGPUTests/Decals` in `Tests/AdaEngineTests`.
  Check that each filter executes the expected cases. Run the owning
  and downstream suites from the runner's GPU and engine profiles.
- Run `script/validate_gpu.sh` on Windows or Linux with SAGA Vulkan and on
  macOS with SAGA Metal. Check actual pass results for the decals suite and
  review any golden images with their backend-specific references. Use the
  release 3D benchmark workflow under `Render3DGPUTests/Benchmarks` for
  timings. Run a WebGPU browser smoke before listing browser support.
- Exercise a deterministic wall, car, and character scene through the
  public API. Use this scene as the runtime-smoke recipe for the contribution
  checker. Retain its results and relevant images for review. Collect native
  platform evidence from the applicable contributor-validation and SwiftPM
  jobs or matching hosts with real GPU execution. Inspect actual job logs
  and supply the feature's runtime recipe where required.
- Ship `Sources/AdaEngine/AdaEngine.docc/Articles/3D/Decals.md` with the
  working Swift example and a link under Topics in
  [AdaEngine.md](../../Sources/AdaEngine/AdaEngine.docc/AdaEngine.md).
  Explain placement failures, the skinned mesh LOD behavior, budgets, and
  verified backend support. Compile and run the example with the same API
  as the runtime test, build [DocC](../../.github/workflows/docs.yml),
  and regenerate and check the offline catalog using
  [the existing generator](../../Editor/scripts/update-offline-documentation.py).
- Track each exact task-owned file with `check_contribution.py scope`
  under task `3d-surface-decals` as paths are chosen. Run
  `check_contribution.py run --task 3d-surface-decals --stage review` with the
  applicable runtime and platform recipes. Send the design, plan, final
  diff, example, and evidence to a separate
  [AdaEngine reviewer](../../.agents/skills/adaengine-review/SKILL.md).
  Fix findings, refresh the affected checks and review, and run
  `check_contribution.py verify --task 3d-surface-decals --stage done`.

## Implementation status

The worktree contains the clipping implementation and a rendered geometry
probe based on the two-joint ribbon. The probe reuses one clipped footprint
across all poses and checks two colored anchors against the original
surface. It draws a temporary mesh to isolate attachment geometry.

The native PBR implementation uses the triangle ordinal of an expanded
draw stream on stamped parts. The projection texture keeps the three
stamp coordinates and the original morph vertex IDs. The fragment shader
uses interpolated barycentric weights to compose coverage and material
channels before lighting. Shadow and motion passes use the original mesh.

The public placement API owns runtime marks in the scene world. Geometry
writes invalidate old stamps. Existing rigid LOD levels retain coverage
where their geometry supports it. Animated meshes and incompatible LOD
replacements use the source geometry while decals are attached.

Ten focused tests passed on Windows with Swift 6.3.1 and SAGA Vulkan.
They cover projection geometry, placement at setup, moving shared meshes,
material channels, skinning and morphs, LOD replacement, occlusion, and
receiver removal. The full Vulkan validation passed 413 tests in 80 suites.
SAGACompiler also emitted both SPIR-V and MSL variants with the expected
texture and sampler bindings. The offline documentation catalog and the
Swift example were checked locally.

Native Metal execution and the release performance measurements remain
open. The complete contribution profile also encountered host and
baseline failures outside the decal tests.
