# Native Animation IK Implementation

Date: 2026-11-06. Status: implementation in progress; no milestone is closed by this plan.
Accepted design: [Native Animation IK](../Designs/animation-ik.md), explicitly approved in
the current conversation's response annotation. Preserve all existing animation-authoring
and control-style work. Existing validation blockers remain open rather than becoming passes.

## Delivery sequence

1. **Pose boundary and numerical solvers.** Add validated, Sendable/Codable configuration
   and compiled instance-local modifier buffers in `AdaAnimation`. Separate evaluated base,
   visual base and final corrected transforms in the existing player. Implement stateless
   two-bone and bounded FABRIK, deterministic degenerate/collinear seeding, measured reach
   error, influence and ordered composition. Keep imported quaternion interpolation unchanged.
   Cover 3D and planar math; planar math alone does not establish native 2D authoring/rendering.
2. **Runtime/resource integration.** Add the versioned `.animmod` resource and backward-
   compatible `Model3DSource` reference/scene overrides. Resolve every model owner, ordinary
   marker and pole from one current local-transform hierarchy snapshot before any stack.
   Declare ECS read/write access and ordering, including voxel transform writers. Reject
   targets under any animated rig and duplicate scene identities. Preserve live valid models
   on invalid replacement; keep strong resource handles and remap/re-resolve scene bindings
   when instancing/navigating. Finalize once after LOD and publish identical node/skin poses.
3. **Shared authoring service and clients.** Implement atomic modifier edits, explicit saving,
   bounded history, reload/conflict recovery, sample diagnostics and revision-checked binding.
   Extend the existing animation request/agent/real Tool VM bridge; preserve permissions,
   callback rollback, queue limits and capability discovery. Do not advertise incomplete actions.
4. **Native Studio workflow.** Add the Modifiers section in the resizable Model panel,
   contextual Inspector fields and viewport target/pole gizmos, sharing the existing player.
   Preserve one-step drag Undo and stable bone IDs. Apply the accepted
   [control rules](../../Editor/Documentation/Design/Controls.md), EN/RU localization and
   unkeyed-pose recovery. Inspector remains the property owner; Graph remains the base-pose canvas.
5. **Native 2D dependencies and IK adapter.** Implement the accepted M5/M6/M7 spatial-path,
   native rig/weighted mesh and spline-chain deliveries as distinct observable slices. Use
   the existing native `Mesh2D` render path, without depending on Spine. Adapt the shared
   solvers while retaining continuous-turn base angles plus shortest corrective deltas.
   Test actual weighted deformation, bounds, scene/resource identity and independent instances.
6. **Animation bindings and complete authoring acceptance.** Connect influence and model-space
   target/pole coordinates to M2's typed animation-property work. Deliver advanced temporal
   curves, path following and spline deformation through their previously approved plan,
   without treating a numerical solver or path follower as the whole requested workflow.

An initial safe default evaluates enabled stateless modifiers on animation-system updates,
including paused clips. LOD may skip base sampling but cannot freeze mutable targets. No
physics/stateful cadence, implicit stretching, general joint limits or full-body IK is introduced.

## Initial ownership and later scope expansion

The runner initially owns the accepted design/approval metadata, this plan,
`Sources/AdaAnimation/Modifiers/AnimationPoseModifier.swift`, `CompiledPoseModifiers.swift`,
`IKMath.swift`, the existing `SkeletalAnimationPlayer.swift`, and
`Tests/AdaAnimationTests/SkeletalIKTests.swift`. Add exact scene, asset, script, Editor and
renderer files before editing each integration slice. Do not sweep unrelated M1 changes into
the new task or alter validation policy to conceal missing platforms/tools.

## Documentation delivered with implementation

Author `Sources/AdaEngine/AdaEngine.docc/Articles/Developers/AnimationIK.md` with executable
Swift examples, spaces/order, defaults, limitations and diagnostics. Link it from DocC Topics
and AnimationAuthoring. Extend `Editor/Documentation/AnimationAuthoring.md`, AnimationGraphs,
the owning asset/agent references, the actual AnimationHelper Tool and offline catalog as their
clients become available. Clearly distinguish mathematical planar support from native 2D mesh
authoring and visible deformation. Do not document unimplemented API as available.

## Validation and completion

### Current 3D slice (2026-11-06)

The 3D base/final pose boundary, two-bone and FABRIK solvers, `.animmod` resource,
scene marker binding, shared agent/Tool requests, Inspector/Model panel and viewport
gizmos are implemented. Focused production-path tests and Windows Studio/Play captures
exercise this slice. Independent interim reviews found numerical near-opposite rotation,
Inspector binding restoration, active-model Undo routing and attached-document lifetime
issues; those have been corrected and covered by regressions. This is progress evidence,
not milestone closure or full accepted-design validation.

Native temporal easing, monotone Bézier sampling, schema-2 persistence and numeric
Inspector handles are implemented as an M2 slice. Native 2D rigs/weighted deformation,
splines, typed animation of modifier properties, Auto Key for those properties,
additional tangent modes/canvas handle dragging and complete platform/render/benchmark
acceptance remain outstanding. Windows DocC conversion currently fails with an invalid
filename; the article's executable Swift example has been compiled/run independently.
Retain these failures and missing platform checks in the contribution report.

- Use Swift Testing through real production evaluators. Each behavior slice records genuine
  Red/Green/Refactor. Minimal new API/data scaffolding may be needed to compile a new test;
  do not count a missing symbol or compilation failure as behavioral Red.
- For fast core iteration use a task-owned dependent Swift package that compiles the actual
  repository `AdaAnimation`/`Math` products and byte-identical owning tests. This is focused
  module evidence, not a substitute for full root/Editor/platform validation.
- Exercise reachable/outer-unreachable/inner-gap/zero-direction targets, arbitrary exported
  axes, pole degeneracy, preserved lengths/scales, rotated parents, uniform versus unsupported
  transforms, influence 0/0.5/1, stack ordering, iteration budgets and deterministic repeated solves.
- Runtime tests compare final nodes and palettes for pause, LOD, seek, crossfade, graph mixing,
  duplication and current moving/deleted/rebound targets. Test target restrictions across rigs,
  malformed resources, path confinement and atomic failed replacement.
- Run real Studio and Play/Tool acceptance from complete staged distributions on supported
  desktop hosts. Capture actual model deformation and native 2D frames; run affected Metal/
  WebGPU golden paths. Numerical samples do not prove rendered IK or a native 2D workflow.
- Build DocC, compile/run examples, validate offline guides/localization, run the full applicable
  contribution profile and independent `adaengine-review`. Fix findings and repeat affected
  checks/review. Missing hardware/tools and failed/timed-out checks remain explicit blockers.
  Do not claim M1, IK or the full M2–M7 request complete until their exit evidence exists.
