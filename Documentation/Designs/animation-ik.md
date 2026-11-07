# Native Animation IK: Two-Bone and FABRIK

Status: **Accepted; implementation and validation in progress.**

Approval: explicit human approval in this Codex conversation on 2026-11-06, in the
annotation on the previously delivered design link, with permission to begin implementation.
The local workflow record attests to that message; it does not authenticate identity.

Implementation plan: [Native Animation IK](../Plans/2026-11-06-AnimationIK.md).

Date: 2026-11-06. Parent: [Animation Authoring](animation-authoring.md).

Request: implement the remaining advanced curves, both confirmed interpretations of 2D
spline support, and actual IK. Curves and native 2D/spline work retain their existing
approval and [M2–M7 plan](../Plans/2026-11-04-AnimationAuthoring.md). This document supplies
the separate solver contract explicitly required by the parent design. Approval of the
parent's modifier preparation did not approve an unspecified solver.

## 1. User outcome and delivery boundaries

A creator can select a rig, add an IK constraint, choose bones and a target, and drag the
target while an imported or authored animation plays. The same result must be available
while paused and from an agent or a developer-authored Tool. A 2D tail can independently
follow a spline and deform its native weighted mesh; moving an entire object on a path
does not count as that deformation workflow.

The requested work has these separately observable outcomes:

| Work | Required result | Existing agreement |
| --- | --- | --- |
| Advanced curves | Named easing families, editable Hermite/Bezier handles and modes, production sampling and undoable edits | Parent section 6, M2 |
| Spatial splines | Editable 2D/3D paths; distance/progress following and optional tangent orientation | Parent section 8, M5 |
| Native 2D deformation | Native rig, weighted mesh, animation, and spline-driven chain deformation | Parent section 8, M6/M7 |
| Pose finalization | Ordered modifiers after mixing/LOD and before final node/skin publication | Parent section 9, M4 |
| Actual IK | Two-bone and FABRIK constraints in 3D and native 2D, specified below | New scope in this document |

This does not withdraw M2's property/playback work or the existing M3 graph roadmap.
New state machines and blend spaces are independent of this solver extension; existing
clip/blend/additive graphs must already compose correctly with it.

## 2. Repository facts and reference choices

`SkeletalAnimationPlayer` owns local poses and global transforms. Sampling and
`presentPose` rebuild transforms internally. `AnimationLOD3DState` presents interpolated
poses, after which `SkeletalAnimation3DSystem` publishes node transforms and skin matrices.
Its paused-player fast path can skip evaluation. A separate system that edits node entities
afterward would disagree with the player, skin palettes and LOD buffers.

There is an existing native `Mesh2D` renderer, but no native 2D skeleton/weight authoring
system in this worktree. The optional Spine integration remains a separate imported-content
runtime and is not a prerequisite for native IK or mesh authoring.

The Godot references are conceptual, not a source/API compatibility promise:

- [SkeletonModifier3D](https://docs.godotengine.org/en/stable/classes/class_skeletonmodifier3d.html)
  applies modifiers after animation mixing and exposes influence.
- [TwoBoneIK3D](https://docs.godotengine.org/en/stable/classes/class_twoboneik3d.html)
  uses a pole target to determine the bend plane.
- [FABRIK3D](https://docs.godotengine.org/en/stable/classes/class_fabrik3d.html)
  solves chain positions; twist and near-root configurations need deliberate behavior.
- [Curve2D](https://docs.godotengine.org/en/stable/classes/class_curve2d.html)
  separates editable Bezier control points from baked distance samples.

These official pages were inspected on 2026-11-06. They are moving references; implementation
must record a source revision if any Godot code is actually reused and preserve its license.
The intended implementation is native Swift math and ECS integration. Do not copy an old
`SkeletonIK3D` workflow into an unrelated late transform system.

## 3. Constraints and persistence

An ordered modifier stack belongs to each rig instance. Entries have a stable ID, display
name, solver kind, bone IDs, enabled flag, influence in `[0, 1]`, target binding and solver
settings. Names are labels; authored bone IDs resolve through the saved rig binding.
Two instances may share immutable configuration but never mutable pose/solver buffers.

Persist model-space solver configuration in a versioned `.animmod` resource owned by
`AdaAssets`; the extension must be registered through the normal resource/document path.
Its binding identifies either the existing complete 3D rig snapshot or M6's native 2D rig.
The scene instance stores the resource reference and scene-target overrides. A scene entity
reference must not leak into a reusable clip/library. Unknown schema versions and changed
rigs fail without rewriting data or guessing from duplicate names.

Each target is either an explicit model-space point or a scene entity plus a local offset.
A detached asset preview supports model-space points and editable viewport target gizmos;
it diagnoses unavailable scene bindings. Scene bindings use stable scene identities and the
current transform hierarchy snapshot. They must not consume stale prior-frame globals.
Scene targets and pole bindings must lie outside all animated rig subtrees in this initial
delivery, including other rig instances. Reject feedback/cross-rig final-pose dependencies
rather than adding an implicit ordering or a previous-frame target. Ordinary scene marker
entities are supported. Resolve all owners, markers and pole offsets from one current
pre-modifier hierarchy snapshot before any instance's stack runs.

Initial bounded limits: at most 32 modifiers per instance, at most 64 segments per chain,
1–64 FABRIK iterations, and a compiled total of at most 32,768 segment-iterations per stack.
Validate limits before allocating solver buffers. Ordinary `.animlib` files and source GLB
files are not rewritten when a modifier resource or scene binding changes.
Reject non-finite points, offsets, influence, tolerances and transform data; enforce exact
component counts and unique bounded IDs in decoded and programmatically edited DTOs.

## 4. Solver behavior

### Two-bone IK

Select three distinct, directly parented joints: root, middle and end. There are exactly two
nonzero segments; imported helper joints require explicitly choosing a compatible chain or
using FABRIK. Validate animated nodes have editable TRS. The solve rotates root and middle;
it preserves local translations/scales and the end joint's authored local orientation.
The resulting world end orientation is not independently locked to the target.

Segment lengths come from the current pre-modifier model-space pose. No implicit stretching
or scale edits are permitted. Clamp an unreachable target to the feasible annulus between
`abs(length1 - length2)` and `length1 + length2`; report reach error. A target at the root or
an exactly folded/straight chain uses the current base-chain direction and a deterministic
orthogonal fallback, never normalization of a zero vector.

3D exposes a pole point determining the bend plane. If target/pole vectors are collinear,
derive the plane from the unmodified base pose; if that is degenerate, use a deterministic
axis chosen by smallest alignment with the chain direction. Do not use last frame's solved
pose as a hidden warm start. In 2D expose a signed bend direction; a pole gizmo selects that
side. Endpoint position is the goal; arbitrary wrist rotation and full-body balance are separate.

### FABRIK

Select an ordered contiguous chain and its target. Keep the root fixed and preserve each
current base-pose segment length. Run full-strength backward/forward passes until endpoint
error is within the configured positive tolerance or the validated iteration budget expires.
Defaults are 16 iterations and tolerance `max(1e-5, chainLength * 1e-4)` in model units.
For a target outside outer reach, extend toward it without changing lengths. An inner
unreachable gap exists if the longest segment exceeds all the others combined: its radius
is `max(0, 2 * longestLength - chainLength)`. Inside that gap, retain the best valid bounded
solve and report original-target error/nonconvergence; do not apply the outer-extension rule.

A straight base chain aimed at an interior reachable target can be a false fixed point even
with nonzero vectors. Detect collinear configurations and introduce a deterministic bend
seed before the first pass: use the base bend plane when available, otherwise the least-aligned
axis (ties X, then Y, then Z), with positive planar bend in 2D. Use a displacement scaled by
chain length and tolerance; full forward passes restore lengths before accepting a candidate.
Near-root and zero-direction cases use the same deterministic policy. Keep the best valid
completed pass by endpoint error, with earliest-pass tie-breaking; never seed from prior
solved state. This does not promise convergence within every selected iteration budget.

Reconstruct local rotations with each rig's actual bone directions and current parent frame;
never assume every bone points along the same exported axis. In 3D preserve base-pose twist
using minimal direction rotation. In 2D use planar signed angles. Leave local scale and
translations intact. Recompute affected globals as needed within the stack.
For a continuous-turn 2D angle, add the shortest corrective delta to this frame's base angle;
do not normalize away its authored full turns. Influence scales that delta once.

The first FABRIK delivery has no general joint-angle or swing/twist constraint system and
no pole guarantee; use two-bone IK for explicitly controlled elbow/knee bending. CCD,
stretching, joint limits, physical/spring solvers, retargeting, automatic rigging, weight
painting and full-body IK remain separately scoped extensions. Do not label them supported.

## 5. Pose pipeline, spaces and failure behavior

The shared finalization order is:

```text
advance playback/graph clocks and markers
  -> sample/mix immutable base local poses
  -> interpolate visual base pose for LOD
  -> resolve current owner and target transforms
  -> evaluate ordered modifiers on scratch poses
  -> blend each modifier's rotation result by influence exactly once
  -> rebuild final globals, publish node transforms and skin palettes
  -> native 2D vertex deformation / render extraction
```

Keep rest, evaluated base and final modified pose buffers separate. Repeated evaluation at
the same base time and targets produces the same pose. Disabling a modifier restores the
current base contribution, not a cached earlier frame. Crossfade sources and LOD endpoints
contain base poses, never poses with IK already applied. Moving targets and changed influence
invalidate finalization even while clip time is paused or LOD skips base sampling. Clock and
marker semantics remain unchanged; target movement and scrubbing emit no gameplay markers.

Solve in model space. World-space targets are converted using the current owner transform.
Initially support rigid transforms and positive uniform owner/ancestor scale. A singular,
reflected, sheared or nonuniform transform on a participating chain is unsupported for IK;
diagnose it and use the current base pose for that modifier. Other animation continues.
Local nonuniform scale elsewhere in the model must not disable an unrelated valid chain.

Static invalid configuration fails atomically before replacing the previous valid draft.
If a scene target disappears or a runtime transform becomes unsupported, skip that modifier
for this evaluation and expose a bounded diagnostic. Never publish NaNs, reuse an old solved
pose, or partly modify the chain. Iteration exhaustion is a valid approximate solve with
`converged = false` and measured error, not a reason to suppress the entire animation.

Initial solvers are stateless. Seek, reverse playback, looping, duplication, project reload
and target rebinding therefore require no undocumented simulation history. Overlapping
constraints execute in saved list order; a later modifier observes earlier blended results.

## 6. Studio, agents and developer Tools

Retain one shared viewport and the bottom Animator. Add a **Modifiers** section to the
resizable Model panel: select, add, remove, reorder and enable constraints. Selecting one
shows bone pickers, target/pole bindings, influence, tolerance/iterations, reach/convergence
and diagnostics in the existing Inspector. The viewport displays chain/target/pole gizmos;
dragging a gizmo is one reversible edit. No second detached animation preview is introduced.

The Animation Graph canvas continues to evaluate the base pose; the Inspector makes the
ordered post-graph modifier stack explicit. Modifiers must not be presented as ordinary
cyclic pose-graph nodes. Influence and model-space target/pole coordinates are registered
animatable properties using M2's typed bindings; scene targets can also move by normal scene
animation. Auto Key uses the same transport/time as the clip timeline.

Proposed shared operations are modifier inspect/apply/sample/save/bind and Undo/Redo, under
the existing animation host service. Typed commands cover add/remove/reorder/update and
target binding. Use resource and scene expected revisions; an atomic bind must include both.
Return capability discovery, typed errors and bounded pose/diagnostic responses. The agent
and real Tool VM consume the same DTOs and commands as Studio. A numerical-only helper that
does not update the scene, preview, history and persisted resource is not API parity.

Reuse the existing project-relative path, import, permissions, conflict and job-size rules.
No unrestricted file writes or arbitrary callbacks are exposed through a solver or Tool.

## 7. Ownership and compatibility

| Owner | Responsibility |
| --- | --- |
| `Math` | Reusable robust vector/rotation/Bezier math; no editor/scene dependencies |
| `AdaAnimation` | Validated modifier DTOs, compiled chains, deterministic solvers and base/final pose boundary |
| `AdaAssets` | Versioned modifier resource IO and rig identity/dependencies |
| `AdaScene` | Current target transforms, per-instance stacks, LOD/scheduling and final publication |
| `AdaSprite` / existing 2D mesh path | M6 deformation output, updated instance bounds and rendering |
| `AdaScripting` | Bounded detached DTO/job bridge and capability catalog |
| `Editor` | Common service/history, Model panel, Inspector, viewport gizmos, agent/Tool adapters |

Legacy scenes with no modifier stack retain their sampling, paused fast path and serialized
representation. Existing linear/step/imported cubic interpolation remains equivalent while
M2 adds native curves; original cubic quaternion derivatives are not scalar Bezier handles.
Native 2D remains usable without the optional Spine dependency.

## 8. Acceptance and documentation delivery

For each solver in each dimension, use real production evaluation to verify reachable and
unreachable targets (including the inner gap), root-coincident cases, a straight chain with
an interior reachable collinear target, preserved lengths, bend direction,
rotated parent frames, supported uniform scale, invalid-chain rollback and influence 0/0.5/1.
Check deterministic iteration limits and no drift over repeated paused/seek/loop evaluations.

Integration tests exercise two independent model instances, crossfade and existing graph
mixing, moving targets under animation LOD, target deletion/rebinding and overlapping stack
order. Compare final node globals, skin palettes and actual visible deformation. Native 2D
acceptance compares final bone poses, weighted vertices, bounds and rendered frames; an
overlay of bones without mesh deformation is insufficient.

Studio tests exercise chain selection, gizmo drag, Auto Key, one-step Undo/Redo, save/reopen
and unsaved-draft recovery. Equivalent UI, agent and real developer Tool commands must
produce equal saved DTOs and samples. Include both successful and stale-revision transactions.

Ship a discoverable DocC article at
`Sources/AdaEngine/AdaEngine.docc/Articles/Developers/AnimationIK.md`, linked from DocC Topics
and the existing AnimationAuthoring article. Extend `Editor/Documentation/AnimationAuthoring.md`,
`Documentation/AnimationGraphs.md`, the owning asset/agent references and offline catalog.
Extend the real AnimationHelper Tool with target/influence controls and document its fixture.
Examples cover a 3D arm/leg target and a native 2D chain/weighted tail, including current limits.

Record genuine Red/Green/Refactor, owning/downstream tests, resource round-trips and dense
chain/editor benchmarks. Build DocC and validate offline guides/examples. Run native Studio
and Play acceptance on Windows and macOS; validate affected Metal/WebGPU rendering and
platform builds using repository checks. Missing tools/hardware remain blockers. Existing
M1 validation blockers are retained separately; this proposal does not close that milestone.

After approval, update the staged implementation plan and exact runner ownership, then
implement curves, the shared pose boundary, the solvers and native spline/deformation
dependencies in observable vertical slices. Obtain independent review before closing each
delivery. This document itself is design evidence, not runtime acceptance.
