# Skeletal animation graphs

`AnimationGraph` combines imported GLB/glTF clips into a single local pose. It is
available through `AdaAnimation` and the `AdaEngine` facade. Each
`SkeletalAnimationPlayer` owns its clock, graph buffers and pending events.
Existing `play("Clip")` calls continue to work and switch back to single-clip playback.

```swift
let graph = AnimationGraph(root: "Locomotion", nodes: [
    .init(id: "Walk", clip: "Walk", events: [
        .init(time: 0.25, name: "Footstep", payload: "left")
    ]),
    .init(id: "Run", clip: "Run"),
    .init(id: "Locomotion", kind: .blend, inputs: [
        .init(node: "Walk", weight: 0.75),
        .init(node: "Run", weight: 0.25)
    ])
])
try animation.player.play(graph)
try animation.player.setGraphWeight(0.4, node: "Locomotion", input: 1)
```

Graphs use stable string node IDs and must be acyclic. A clip node references an
imported clip by name. Blend nodes combine their inputs per joint: weights above
one are normalized; weights below one leave the remaining contribution in the
rig's rest pose. Quaternion blending uses a common hemisphere and normalization.
Zero weights keep branches silent without restarting their clocks.

An additive node's first input is the base pose. Later inputs add local
translation, rotation and scale changes relative to the rig's rest pose.
Additive input weights are clamped to 0...1. Absolute clips should be authored
against the same rest pose; this API does not perform retargeting or extract
root motion. Input order controls the order of additive rotations.

```swift
let upperBody = AnimationGraph.Mask(joints: [
    .init(nodeIndex: chestNodeIndex, weight: 1, includesDescendants: true)
])
// Append an additive output combining locomotion and an upper-body clip:
let layer = AnimationGraph.Node(id: "AimLayer", kind: .additive, inputs: [
    .init(node: "Locomotion"),
    .init(node: "Aim", weight: 0.5, mask: upperBody)
])
```

Mask indices identify nodes in the imported model hierarchy, rather than offsets
in a skin's joint palette. The default weight applies to all nodes; ordered
entries override a bone or its subtree. Imported rig nodes retain names for
authoring. Masks do not alter matrix-authored static nodes.

## Clip events

Markers belong to clip nodes and contain seconds, a name and an optional text
payload. `Model3DPlugin` forwards crossings as
`Events<ModelAnimation3DEvent>`, with the model root ID, clip/node identity and
graph contribution. Gameplay can filter low-weight footsteps during blending.
Shared graph nodes emit one crossing with combined contribution.

Events follow playback clocks even when offscreen animation LOD skips pose
sampling. Forward intervals are `(previous, current]`; reverse intervals are
`[current, previous)`. Loops and multi-loop steps are handled. A time-zero marker
fires on later loop boundaries; starting playback does not emit it. Pause, Seek,
graph replacement and visual interpolation do not emit crossings.

Direct player users call `drainGraphEvents()` once after advancing. Queue/work
is capped at 1,024 occurrences per undrained update sequence; overflow is exposed
by `droppedGraphEventCount`. Seek clears pending markers. Graph installation
validates atomically and leaves current playback intact when validation fails.

## Ada Studio

Open a GLB/glTF asset and choose **Animation Graph**, or select a Model 3D entity
in a scene and open **Animator → Skeletal Graph**. The shared editor provides:

- Clip, blend and additive nodes, output selection and input connections.
- Clip speed/loop controls and live weights.
- Bone/subtree masks, their weights and default weight for other bones.
- Clip event time, name and payload.
- A real rendered model preview; scene Animator includes Play/Pause, Seek and
  the latest emitted event.

Invalid drafts display diagnostics and keep the last valid preview graph.
**Apply to Scene** writes structured graph data into `Model3DSource.animationGraph`
as one undoable edit; Save persists it in `.ascn`. Autoplay controls game/scene
playback independently from preview playback. **Use Single Clip** removes the
graph while retaining the original clip settings. Asset-preview **Add to Scene**
also carries the edited graph. The scene loader instantiates the same graph in
edit and Play, with independent players for duplicated model instances.

This editor authors graphs through a node list and explicit input connections.
It does not edit imported skeletal keyframes or retarget skeletons. The existing
scene keyframe timeline remains available through the **Keyframes** mode.

## Validation snapshot — 2026-10-06

- Swift 6.2.4/macOS: final engine executable passed all 1,277 tests in 232 suites.
  Optional dSYM generation hit a disk-space limit; tests ran from the completed
  executable after removing only task-owned intermediates.
- Graph, imported-model and keyframe Editor checks passed 17 tests in three suites,
  including real AdaUI taps, scrolling, fractional text input, scene Save/reopen,
  undo/redo, preview pause/seek and editing without restarting its clock.
- The initial expanded Editor run passed 55 of 58 tests. The three viewport
  failures were subsequently resolved: pan/mixed-render fixtures now explicitly
  account for the default 150-point world-unit scale, and picking composes current
  local hierarchy transforms and unprojects the displayed camera, including the
  2D/3D transition. The final viewport/gizmo/model/animation regression run passed
  88 tests in 11 suites, with projection, pre-propagation edits and parent-transform
  coverage. Gizmo fixtures explicitly select their intended one-point/unit scale.
- A separate macOS QA Studio bundle built and launched through the existing
  development script; its native process remained running. Native visual layout,
  graph preview pixels and physical/mobile-device interaction were not inspected.
- Task-owned runtime/graph/editor/test files pass strict SwiftLint and the final
  diff passes `git diff --check`. Existing model-preview files retain their
  earlier conditional-return lint baseline.
