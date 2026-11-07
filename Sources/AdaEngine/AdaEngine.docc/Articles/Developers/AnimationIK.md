# Animation IK and pose modifiers

Constrain a skeletal chain after its clip, Animation Graph and visual LOD pose have been mixed.

IK belongs to each playback instance. Editing a target does not rewrite the imported GLB or
bake corrections into an animation library. An ordered stack supports two-bone IK and FABRIK.

## Solve an editable chain

This complete example constructs two unit segments and moves their endpoint. For an imported
model, use its full rig binding; skin-palette indices are not stable bone IDs.

```swift
import AdaAnimation
import Math

let poses = [SkeletalJointPose(), SkeletalJointPose(translation: [1, 0, 0]),
             SkeletalJointPose(translation: [1, 0, 0])]
let rig = try SkeletalRig(nodes: poses.indices.map { index in
    .init(parentIndex: index == 0 ? nil : index - 1,
          restPose: poses[index], restMatrix: poses[index].matrix)
})
let binding = AnimationRigBinding(rig: rig, sourceAsset: "Assets/Robot.glb")
var player = try SkeletalAnimationPlayer(rig: rig, clips: [])
let arm = AnimationPoseModifier(id: "arm", kind: .twoBone,
    joints: ["node-0", "node-1", "node-2"], target: [1, 1, 0], pole: [0, 0, 1])
try player.setPoseModifiers([arm], binding: binding)
assert((player.globalTransforms[2].origin - Vector3(1, 1, 0)).length < 0.0002)

// Transient scene input does not change the saved stack or advance the clip clock.
player.finalizePoseModifiers(inputs: ["arm": .init(target: [0, 2, 0])])
assert(player.basePoses == poses)
```

`setPoseModifiers` validates before replacing the stack. Chains are contiguous and have
editable TRS and nonzero segments. Two-bone IK requires exactly three joints. FABRIK accepts
1–64 segments, 1–64 iterations (default 16) and a positive tolerance. Its automatic tolerance
is `max(1e-5, length * 1e-4)`. Influence is in `0...1`; coordinates must be finite. A stack has
at most 32 modifiers and 32,768 compiled segment-iterations. Neither solver stretches bones.

## Separate base and final poses

`basePoses` contains animation/graph/LOD output. `poses`, local/global transforms, scene
bones and skin palettes contain the final constrained result. Repeated finalization starts
from the same base pose, without accumulating corrections. Crossfade sources and LOD
endpoints also contain base poses. Moving targets and paused clips still finalize active IK;
target movement does not emit animation markers or advance playback clocks.

Modifiers execute in saved order, each observing the previous influenced result. Influence
blends local rotations once. Local translation, scale and the end joint's authored local
rotation remain intact; its world orientation is not independently locked. Rigid transforms
and positive uniform scale are supported. An unsupported participating hierarchy skips that
modifier; unrelated nonuniform branches do not disable valid chains.

Read `modifierDiagnostics` for each stable modifier ID. `solverError` measures the
full-strength solution; `reachError` measures the published endpoint after influence.
Unreachable targets and iteration exhaustion can produce valid approximate results. Missing
targets skip their modifier instead of holding an old solved frame. CPU samples do not prove
rendered output.

## Resources and scene bindings

`AnimationModifierStack` stores a versioned full-rig snapshot and an ordered list. Bounded
JSON uses `.animmod`; `AnimationModifierResource` supplies normal asset codecs. Unknown
versions and changed rigs are rejected. `Model3DSource.animationModifiers` loads the stack
before replacing a live model. Scene overrides remain in `Model3DSource.modifierBindings`.

An `AnimationIKTarget3D` is a model-space point or a stable scene entity ID with a local
offset. Studio assigns `AnimationSceneIdentity3D` to authored entities. Programmatic scenes
assign a shared namespace to the model owner and its ordinary target markers. Namespaces
isolate loaded scene instances; runtime Entity.ID values are never persisted as targets.

Owners and marker offsets resolve from one current local-transform snapshot before applying
any stack. A marker beneath any animated rig is rejected, including another instance.

## Studio, agents and developer Tools

Open a GLB/glTF or `.animmod`. **Modifiers** is in the resizable Model panel. Select a
contiguous chain, then add **Two-bone IK** or **FABRIK**. The Inspector owns chain, target,
pole, influence and solver settings. Blue target and purple pole handles preview a drag;
release creates one Undo entry and Escape cancels. Save explicitly before binding to a scene.

Agents call `editor.animation.modifierInspect/Create/Apply/Sample/Save/Undo/Redo/Preview/Bind/Reload/Discard`
(each suffix is a separate action, for example `editor.animation.modifierApply`). API 2 Tools
submit the same `AnimationAuthoringRequest` through `editor.animations.submit` and poll
asynchronously. Edits use the inspected `expectedRevision`; binding also requires a current
`sceneRevision` and a saved compatible stack. Standard animation read/write, preview and
document-write permissions apply. See <doc:AnimationAuthoring> for job limits and transport.

This article describes 3D skeletal IK. Native 2D weighted deformation, continuous-turn angles,
spline-chain authoring and typed timeline bindings for modifier parameters remain separate
implementation stages. A 3D numerical solve does not establish those workflows.
