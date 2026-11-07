# Authoring skeletal animation

Copy an imported animation or capture a rest/current pose into a project-owned
`.animlib` resource. Source GLB/glTF bytes remain unchanged. Swift code, Studio's
Animator, the editor agent and project Tools share the same data and edit commands.

Opening a GLB/glTF or `.animlib` in Studio reveals the bottom **Animator**. A
resizable **Model** panel shows the imported node hierarchy, and the right Inspector
follows bone, track, key and graph selection. The timeline places all bones on a
shared seconds ruler with a draggable playhead, clip/duration/loop controls, key
insertion and grouped editing. Graph uses connected pose cards on a canvas.
These surfaces share the large center viewport's player and camera. Asset editing
does not require an open scene. See the Studio animation-authoring guide for the
complete pointer and keyboard workflow.

## Create a library

A binding snapshots the complete hierarchy: stable node IDs, parents, names, rest
matrices/TRS and morph target widths. Tracks target hierarchy nodes, including
non-joint nodes, rather than offsets in a skin palette. Changed rigs fail binding
explicitly; guessing by duplicate bone names or reordered indices is not remapping.

```swift
import AdaAnimation
import Foundation

let rig = try SkeletalRig(nodes: [
    .init(parentIndex: nil, restPose: .init(), restMatrix: .identity, name: "Root")
])
var library = AnimationLibrary(id: "hero", binding: .init(rig: rig, sourceAsset: "Assets/Hero.glb"))
let clip = try library.poseClip(id: "wave", name: "Wave", duration: 1)
try library.apply([.init(id: "create-wave", kind: .createClip, clip: clip)])
// This known one-bone rig has one rotation track in the captured pose clip.
if let rotation = clip.tracks.first(where: { $0.channel == .rotation }), var key = rotation.keys.first {
    key.value = [0, 0, 0.70710677, 0.70710677]
    try library.apply([.init(id: "rotate-root", kind: .putKey, clipID: clip.id,
                             trackID: rotation.id, key: key, replaceExisting: true)])
}
let reopened = try AnimationLibrary.decode(library.encodedData())
let player = try reopened.sample(clipID: "wave", at: 0.5)
```

Use `library.extract(clip, rig: rig)` to copy a runtime clip from the same source rig.
Translation, normalized XYZW quaternion rotation, scale and morph-weight tracks
retain their linear/step/cubic-spline values and derivatives. Explicit clip duration
preserves a hold after the last key. `poseClip(name:duration:from:)` can capture a
compatible player's local pose/morphs. Matrix-authored static nodes retain matrices.

## Edit keys and play clips

`AnimationEdit` supports `clip.create/duplicate/remove/configure`,
`track.create/remove/configure` and `key.put/remove`. IDs are scoped to the library,
clip and track respectively. Duplicated clips own independent value data.

Batches are atomic. Each operation leaves a valid document; an invalid operation
reports its ID and preserves the original library. Updating/moving an existing key
ID requires `replaceExisting:true`. Another key at the same time remains a conflict
and must be removed explicitly. Keys use finite seconds in strictly increasing
order within duration, typed finite values, and normalized quaternion rotations.
Cubic incoming/outgoing tangents are component derivatives per second.

## Native temporal curves

Key `curve` metadata adds easing to the outgoing segment. Families are linear,
quadratic, cubic, quartic, quintic, sine, exponential, circular, back, elastic and
bounce; directions are `in`, `out`, `inOut` and `outIn`. Back exposes overshoot;
elastic exposes amplitude and period. Overshoot is retained rather than clamped.

```swift
import AdaAnimation

let pose = SkeletalJointPose()
let rig = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix)])
var library = AnimationLibrary(binding: .init(rig: rig, sourceAsset: "Assets/Hero.glb"))
let track = AnimationLibraryTrack(id: "move", nodeID: "node-0", channel: .translation, keys: [
    .init(id: "start", time: 0, value: [0, 0, 0]),
    .init(id: "end", time: 1, value: [1, 0, 0])
])
try library.apply([.init(kind: .createClip, clip: .init(id: "move", name: "Move", duration: 1, tracks: [track]))])
var key = track.keys[0]
key.curve = .init(easing: .init(family: .quadratic, direction: .in))
try library.apply([.init(kind: .putKey, clipID: "move", trackID: "move", key: key, replaceExisting: true)])
let player = try library.sample(clipID: "move", at: 0.5) // translation.x is 0.25
let reopened = try AnimationLibrary.decode(library.encodedData())
```

For translation, scale and morph weights, `bezier` interpolation accepts per-component
`curve.incoming` and `curve.outgoing` arrays of `AnimationBezierHandle`. Each handle
stores a time offset in seconds and a value offset relative to its key. Missing
handles default to one third of the straight segment. They are distinct from
Hermite's `incoming`/`outgoing` derivatives on the key itself. Sampling first inverts
monotone Bézier time, applies easing to that parameter and then evaluates the value.
Reversing temporal curves, invalid dimensions, non-finite values and unsafe Float
ranges fail before replacing the document. Flat and crossing temporal controls are
supported when their full time polynomial remains monotone.

Quaternion linear tracks use shortest-path slerp with eased progress. Imported cubic
quaternion tracks retain their normalized component interpolation; easing remaps
their segment parameter. Arbitrary scalar Bézier handles are rejected on rotations.
Unedited linear/step/imported cubic tracks retain their existing evaluator.

Edits and extraction promote native curve data to `.animlib` schema **2**. Legacy
libraries without that data remain schema 1; old readers must reject schema 2 rather
than silently remove its curves. A library permits at most 500,000 compiled native
scalar segments in addition to its existing key/byte limits. A sparse easing edit
only compiles the changed segments; Bézier tracks compile every scalar segment.
The same key payload goes through `key.put` from native Inspector, agents and Tools,
including resource revisions, atomic rejection, history and explicit Save.

Load `AnimationLibraryResource` through AssetsManager or decode its JSON, then
provide libraries to `Model3DSource.instantiate(_:libraries:in:under:)`. The source's
`animationLibraries` references and loaded libraries must match in count/order.
Distinct library IDs, compatible bindings, imported/authored name collisions and
the complete graph validate before runtime entities are allocated.

Use `library.runtimeName(for: clipID)` for a single animation or an existing
`AnimationGraph` clip reference. Display names may repeat; qualified names encode
library/clip identity. Native compiled tracks retain the existing mixer, crossfade,
repeat/one-shot clock and skin-palette behavior. Each player owns mutable poses.

## Studio and automation

Select a Model 3D entity and open **Animator → Bone Keyframes**. Extract a copy or
create a rest-pose clip, select bone/node tracks and edit keys. The model viewport
shows the animated mesh and bones. **Save and Bind** explicitly saves the resource
and performs a separate undoable scene transaction. The graph picker includes
bound saved clips. Inspector edits easing and per-component Bézier offsets; Curves
plots the production evaluator. Additional tangent modes, canvas handle dragging,
state machines/blend spaces, paths and native 2D spline deformation remain later work.
Procedural 3D IK is described below.

The editor agent calls `editor.animation.<action>` with a `requestJSON` string
containing `AnimationAuthoringRequest`. Studio API 2 project Tools use
`editor.animations.submit(requestMap)` and `poll(jobID)`. All clients share the same
project drafts/history. Inspect first for stable IDs and `revision`; writes require
`expectedRevision`. Binding also needs an open scene revision and saved resource.
Drafts require explicit Save. Reload/Discard recover external-file conflicts.

Requests support 64 KiB, responses 1 MiB, pages 256 items and batches 256 operations.
Libraries/model imports support 32 MiB; a library allows 16,384 nodes, 256 clips,
4,096 tracks per clip, 100,000 keys and 1,024 morph targets per node. IDs are limited
to 256 UTF-8 bytes, names to 1,024, source paths to 4,096 and fingerprints to 256.
Large morph-key pages may need smaller limits. CPU samples and preview
acknowledgements do not establish pixels: verify the viewport and visible Play.

## Save and bind from Swift

Given a model compatible with the library's complete rig and an existing owner in
its world, explicitly save the resource and instantiate an authored clip:

```swift
import AdaEngine
import Foundation

func saveAndBind(_ library: AnimationLibrary, resourceURL: URL, resourceReference: String,
                 model: ModelAsset3D, world: World, owner: Entity, clipID: String) throws {
    try FileManager.default.createDirectory(at: resourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try library.encodedData().write(to: resourceURL, options: .atomic)
    let reopened = try AnimationLibrary.decode(Data(contentsOf: resourceURL))
    let source = Model3DSource(source: reopened.binding.sourceAsset,
                               animation: reopened.runtimeName(for: clipID), autoplay: true,
                               animationLibraries: [resourceReference])
    _ = try source.instantiate(model, libraries: [reopened], in: world, under: owner)
}
```

Use a project-owned resource URL and its portable `@res://Animations/Hero.animlib`
reference. For an imported model, derive the binding from
`GLTFAnimationAdapter.makeRig(nodes:meshes:)` using that model's native import data,
then extract its compatible clip. The synthetic Root rig above is only for a model
with that same rig; incompatible models fail explicitly. Studio Tools can follow
the complete bone-key, sample, Save and Bind workflow in the AnimationHelper example
linked from the Studio guide. Native Tools bound expanded request conversion to
8,192 values and 64 KiB of UTF-8 strings, and restricted imports preflight repeated
decoded accessor work before allocation.

Native hosts can construct a preview with `ModelAsset3D(gltfAt:loader:)`, supplying
`NativeGLTFLoader(resourceRoot:maximumTotalBytes:)` for the full model import. Studio's
library viewport uses this scoped loader; it does not change the global resolver.

Studio's shared request envelope also carries `graphInspect`, `graphApply`,
`graphUndo`, `graphRedo`, `graphPreview` and `graphBind`. These address an open
model/library workspace and use its graph revision rather than the clip-library
revision. `graphApply` replaces a detached `AnimationGraph` in the same canvas
history. Binding validates the complete destination rig and saved libraries,
then commits one scene-history edit. See the Studio guide and AnimationHelper
example for request maps, separate permissions, budgets and explicit scene Save.

## Procedural IK after animation

See <doc:AnimationIK> for ordered two-bone/FABRIK constraints, model-space targets,
current scene marker bindings, `.animmod` resources and the shared Tool/agent API.
