# Editing bone animation

## Recognizing controls

Actions in Inspector, Animator and Graph have a visible button surface and border.
The primary action and active modes/toggles use the blue accent; disabled actions
remain outlined with reduced emphasis. Editable text and number fields use the
same themed borders as the scene Inspector, including the scene Graph's time field.
Pose components have inline X/Y/Z/W badges (red, green, blue, purple) so translation,
scale and quaternion values are easy to scan. These colors supplement the axis letters.

An overflowing Inspector or Model hierarchy shows a scroll indicator. Resize the
panel or scroll to reach the remaining controls. The detailed contributor rules are
in [Studio control design](Design/Controls.md).

## Open an animation workspace

Open a GLB/glTF asset. The **Model** panel beside the viewport lists its complete
node hierarchy. Drag its divider to change the width; the **Model** button hides
or reopens it. Search retains matching nodes and their parents. Click a node to
select it; Ctrl/Cmd-click adds to the selection, Shift-click selects a range, and
**Select Subtree** selects its descendants. The project file tree remains separate.

The right **Inspector** follows the selected node, track, key or graph node.
Choose an imported clip in the bottom **Animator**, then use **Extract Editable Copy**
in Inspector. **New Animation** starts from the rig's rest pose. Set a
project-relative destination such as `Assets/Animations/Hero.animlib`.
The original GLB/glTF stays unchanged. Opening an `.animlib` asset uses the same bottom Animator. The large center viewport
shares one preview/player/camera with Model, Inspector and the bottom Animator controls.
Opening a GLB/glTF or `.animlib` reveals Animator automatically. An open scene is not required to edit a model asset. Switching modes or hiding Animator
does not reload the model. Save the library before using **Add to Scene**; its saved
library references accompany the selected authored clip or graph.

## Timeline and keys

All bone rows share one seconds ruler and playhead. Expand a bone row to see
translation, rotation and scale channels; imported morph-weight tracks also appear.
Collapsed rows summarize keyed times. Click or drag the ruler to pause and preview
the exact time, or enter **Seconds** and click **Seek**. Transport offers play/pause,
stop-to-start, previous/next key and frame stepping. **Fit** shows the clip's time
range. Scroll vertically through rows; Shift-scroll moves along time and
Ctrl/Cmd-scroll zooms around the pointer.

The filter row offers name search, selected-only bones, animated-only tracks and
channel type. These controls remain available without opening Inspector.

Select bones or channel rows before **Insert Key**. Insertion updates a key already
at that track/time. Select keys individually or with a rectangle, then drag them
horizontally as a group; **Snap** toggles frame snapping. Dragging preserves relative
times. Release commits one Undo operation, and Escape cancels the draft. A collision,
an out-of-range time, or a concurrent resource edit rejects the entire move. A move
replaces complete affected tracks through the same bounded API described below; groups exceeding
the batch budget must be reduced.

Selecting a bone row inserts translation, rotation and scale. Selecting a channel
row inserts only that channel, including a channel without an existing track.
Morph rows sample the current morph weights. Shift-click keys selects a time range
on the anchor and clicked tracks. The unkeyed-pose **Insert Key** decision commits
all staged TRS channels; a channel-specific insertion keeps other staged channels
pending. Closing an asset also waits for its unkeyed pose to be keyed or discarded.

Inspector edits a selected key's exact time/value and current interpolation's raw
tangents. Update moves its stable ID; Delete removes selected keys. Occupied times
are never overwritten implicitly by moves. **Duration** must include every key;
extending it holds the last pose, while a reduction past keys is rejected. **Loop**
controls repeat. Rotations accept
normalized XYZW quaternions or Euler degrees in the displayed Z, X, Y application
order. Imported cubic tracks preserve editable raw incoming/outgoing derivatives.

Select a key to edit **Outgoing segment easing** in Inspector. Choose from linear,
quadratic, cubic, quartic, quintic, sine, exponential, circular, back, elastic and
bounce, with `in`, `out`, `inOut` or `outIn` direction. Back exposes **Overshoot**;
elastic exposes **Amplitude** and **Period**. **Apply Curve** commits the fields as
one Undo operation. Text drafts do not change the current animation before Apply.
Easing has no effect on step interpolation or after the final key.

Choose **bezier** interpolation on a translation, scale or morph-weight track to
edit its handles. Select a component, then edit incoming/outgoing **Time offset**
and **Value offset** relative to the selected key. Boundary keys expose only the
handle that belongs to an existing segment. Changes must leave time monotone;
invalid edits preserve the previous curve. The handles use seconds/value units,
while imported cubic tangents are derivatives per second. Quaternion tracks offer
easing with their existing interpolation, without scalar Bézier handles.

**Curves** samples the same evaluator used by scene playback. Recapturing an
existing key preserves its curve metadata. Native curves save in `.animlib` schema
2; old editors must reject that version. Unchanged legacy libraries remain schema
1. Save/reopen and the shared API preserve easing and all component handles.
Additional tangent modes, dragging handles on the canvas, graph orchestration,
paths and native 2D deformation remain later work.

**Preview Pose** changes the selected bones temporarily. Editing one component
preserves each bone's other components; switching rotation representation keeps
the current orientation. **Insert Key** commits the pose in one resource operation;
**Auto Key** inserts immediately. An unkeyed pose must be keyed or discarded before
changing time, clip, library or graph preview. **Cancel** keeps the pose and cancels
the requested switch. Concurrent resource changes require discarding the stale pose.
Use the viewport's **Preview Settings** button for projection, background, lighting,
grid and axes. **Save Preview Workspace** retains panel/graph/selection and preview
state under the project's `.ada/workspace`.

## Node Graph

**Animation Graph** opens a canvas of clip, blend and additive cards connected by
pose wires. The card marked **Output** is the root. Drag a pose output to an input
or **+ Input** to connect it. Drag a connected input to reconnect its wire; its
weight and mask travel with the connection. Cycles are rejected. The Inspector
edits clip settings, connection weights and bone/subtree masks. In additive nodes,
the first input is the base pose.

Drag cards to arrange them, use middle-drag or **Pan** to move the canvas, scroll
to zoom, and **Fit** to reveal the graph. Select a card or wire and press Delete;
Undo/Redo restores complete operations. Invalid/incomplete graph drafts show
diagnostics while the viewport retains its last valid graph. Scene graph data
saves through the model's scene component; asset preview/layout state and library
key data have separate destinations. **Save** on a library saves its clips.

Edits are shared drafts with Undo/Redo. **Save** writes explicitly. Autosave, tab
switches and attempting to close a dirty library do not save it. **Save and Bind**
saves the resource, then attaches it through the scene's own Undo history. Scene
Undo does not undo an already saved resource. The existing Skeletal Graph selects
bound saved authored clips by their qualified runtime names.

Bindings preserve hierarchy/rest pose, non-joint nodes and morph widths. Changed
rigs require explicit remapping; name/index guesses fail. Multiple libraries need
distinct library IDs. Scene references stay inside Assets, including relative
references and symlinks. Verify viewport animation and game-camera Play separately.

If a file changes externally, Save reports a conflict. Use **Reload from Disk** on
a clean document, **Discard Local Edits and Reload** to explicitly replace the draft,
or **Discard Draft** to close it without writing/deleting its file. New/discarded
drafts can be reopened or recreated.
These recovery actions are in the right Inspector's library controls. Resolve an
unkeyed preview pose before reloading or discarding the library.

## Agent request contract

Every `editor.animation.<action>` tool takes `requestJSON`: a JSON string containing
an `AnimationAuthoringRequest`. Its `action` must match the tool name. Actions are
`inspect`, `create`, `extract`, `apply`, `capture`, `sample`, `validate`, `save`,
`undo`, `redo`, `bind`, `preview`, `reload`, `discard`.
Graph actions are `graphInspect`, `graphApply`, `graphUndo`, `graphRedo`,
`graphPreview`, `graphBind`.

Inspect first:

```json
{"action":"inspect","path":"Assets/Animations/Hero.animlib","limit":32}
```

The response contains `revision`, `libraryID`, clips and a page of node bindings.
Add `clipID` for tracks and `trackID` for keys. `offset`/`limit` select pages (maximum
256 items). Clips and nodes/tracks use the same offset; target a clip/track when
paging keys. Read stable IDs rather than deriving them from display names.

Extract an imported clip into an unsaved copy:

```json
{"action":"extract","path":"Assets/Animations/Hero.animlib","modelPath":"Assets/Models/Hero.glb","sourceClip":"Walk","name":"Walk edited"}
```

Existing destinations require `expectedRevision`. `create` takes the same paths
and makes a rest-pose clip. `capture` samples a library `clipID` at `time`, creating
a new pose clip with optional `name`/`duration`. Their responses give `createdClipID`.

Update an inspected rotation key atomically:

```json
{"action":"apply","path":"Assets/Animations/Hero.animlib","expectedRevision":"<revision>","operations":[{"id":"raise-arm","kind":"key.put","clipID":"<clip>","trackID":"<rotation-track>","replaceExisting":true,"key":{"id":"<key>","time":0.5,"value":[0,0,0,1]}}]}
```

A new key uses a fresh ID and omits `replaceExisting`. `track.create` supplies
`track` with `id`, `nodeID`, `channel` (`translation`, `rotation`, `scale`, `weights`),
`interpolation` (`linear`, `step`, `cubicSpline`) and `keys`. Cubic keys need sized
`incoming`/`outgoing` derivatives per second. Every operation leaves a valid document;
one failure rolls back the batch and identifies its operation ID.

`clip.configure` accepts `name`, `duration`, `repeats`; `clip.duplicate` needs `newID`
and `name`; `track.configure` accepts `interpolation`. Remove operations identify
`clipID`, `trackID`, `keyID` as applicable. `clip.create` supplies a full `clip`.

Save with `{"action":"save","path":"…","expectedRevision":"…"}`. Bind additionally
supplies open `scenePath`, `entityID`, `sceneRevision`, `clipID`. It checks all saved
libraries, imported clips and the current graph before one scene transaction.
`sample` returns paginated TRS/morphs plus `hasTRS`, `localMatrixColumnMajor` and
`globalMatrixColumnMajor` (16 column-major floats in model/rig space, before the scene instance transform). Matrix-authored nodes retain
their matrices; their fallback TRS is not a decomposition. `validate` optionally takes `modelPath`
to check the rig. `preview` opens the library viewport at `clipID`/`time`; wait for
load and capture the editor for visual proof. CPU samples/preview requests do not
prove rendered output. `reload` needs a revision; dirty reload and `discard` also
need explicit `discardChanges:true`. Mutation acknowledgements contain the new
revision/dirty state; inspect separately for detailed data.

For graph actions, `path` addresses an **open** GLB/glTF or `.animlib` asset.
Open its viewport and call `graphInspect`; wait until `ready:true`. Its `revision`
is the graph revision, separate from the optional `resourceRevision`. Inspect returns
`root` and paginated `nodes` in the runtime `AnimationGraph` schema. `graphApply`
takes `graph:{root,nodes}` and the graph's `expectedRevision`; it atomically replaces
the same draft used by the canvas. Incomplete drafts retain diagnostics. Active
canvas gestures reject API writes. Card movements do not change the semantic graph
revision, while graph changes and graph Undo/Redo do.

`graphPreview` needs a valid graph, its revision and optional finite `time`.
`graphBind` additionally takes `scenePath`, `entityID` and `sceneRevision`; it validates
the destination model and its saved library bindings before one scene-history edit.
The graph draft/layout remains editor workspace data until explicitly applied to a
scene. Library Save does not publish a preview graph into a GLB or `.animlib`.
Graph actions use the same 64 KiB request limit; `graphApply` allows up to 4,096
cards and 16,384 total inputs/markers within that limit.
The runtime currently validates at most 256 cards and 64 inputs per card. Larger
drafts remain invalid. Studio additionally bounds compilation to one million
pose/mask cells, one million morph cells and four million ancestor checks. Reduce
cards or mask entries when a preview exceeds these budgets. Scene binding requires
the same complete rig; matching clip names alone do not establish compatibility.

## Project Tools

[Studio Tools](StudioTools.md) API 2 exposes the identical contract through
`editor.animations.submit(requestMap)`. Successful callbacks publish detached jobs;
do not mix them with entity-creation batches. A later button/action calls `poll(jobID)`
and receives a detached Map with `status` (`pending`, `completed`, `failed`) and
`result` or `error`. Do not busy-wait inside a callback. A successful terminal poll
consumes the result. Disabling/replacing a Tool or closing its project cancels its
generation's pending jobs.

Declare `editor.animations.read`; edits/save/reload/discard also require
`editor.animations.write`; preview requires `editor.animations.preview`; bind needs
`editor.documents.write`. The example also reads the active scene through `editor.documents.read`. API 1/document grants confer no animation access. Declare
`platforms:["macos","windows"]` for native desktop hosts.
The same grants apply respectively to graph edits/Undo/Redo, graph preview and graph binding.

Limits: 64 KiB requests, 1 MiB responses, 8 submissions per callback, 16 retained
jobs, 256 operations/batch, 256 items/page, 32 MiB library/model import. A library
allows 16,384 nodes, 256 clips, 4,096 tracks/clip, 100,000 keys and 1,024 morph targets
per node. IDs have 256-byte UTF-8 limits, names 1,024, source paths 4,096 and
fingerprints 256. Large key pages may need smaller `limit`. These in-process
capabilities/budgets are not an OS sandbox. Swift users share `AnimationLibrary`,
`AnimationEdit` and the native compiled tracks.

## Run the complete Tool example

Copy `Examples/StudioTools/AnimationHelper` into the project's `Tools` directory.
For the repository's GardenRobot fixture, copy `Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb`
to `Assets/Robot.glb`. Open a scene containing a Model 3D entity with that source;
set the Tool's entity ID to its stable scene ID (`robot` in the acceptance fixture).

Extract `Walk`, then Poll. Inspect Rotation Tracks, Poll, Inspect First Key, Poll.
The fixture's first rotation track targets `Foot.L`. Set Bone Local Z Rotation to
90 Degrees, Poll, and Sample, Poll. The Tool reads the selected node's quaternion
from the nested pose response. Sampling reads at most eight nodes per job; keep
clicking Poll while another page is queued for a later bone. Small response pages
keep the synchronous Tool callback within its execution budget. Save, Poll, then Bind, Poll. These are separate
explicit operations; inspect the library viewport and Play to assess the pose.
The sample replaces a linear key's absolute local rotation; it is not a retargeter
or a cubic-tangent editor. For other rigs, inspect and choose compatible IDs through
the same API. The supplied test executes this actual `.ada`/`.ui` example through
the real Tool host and compares its key edit with native UI and agent commands.

For its graph example, open `Assets/Robot.glb` and wait for the model. Choose
**Inspect Open Model Graph**, Poll, then **Replace Preview Graph with Half-Weight
Clip**, Poll. The source clip is blended with the rest pose. **Preview Graph**,
Poll opens that same draft in the canvas. With a compatible model entity in an
open scene, **Apply Graph to Scene Entity**, Poll writes one undoable scene edit;
Save the scene to retain it. The Tool keeps graph and library revisions separately.

Tool request conversion additionally limits expanded values (including Map keys)
to 8,192, cumulative UTF-8 string bytes to 65,536 and nesting to 64. Shared subgraphs
consume the budget on every expansion. Import preflight caps each top-level
inventory at 16,384, primitives/samplers/channels at 4,096 per owner and total decoded
accessor work at 32 MiB of Double elements, charging repeated references. These
checks happen before accessor allocation. Encoded files and local/data resources
have a separate 32 MiB limit.

The library viewport uses its own restricted native loader all the way through GPU
model construction. It does not preflight then reopen the source with the ordinary
loader. The scene Animator reads initial clip names through the CPU authoring service.


## IK modifiers

Open a GLB/glTF or `.animmod` asset and expand **Modifiers** in the resizable Model panel.
Select a contiguous bone chain (three joints for two-bone IK), then add **Two-bone IK** or
**FABRIK**. The existing Inspector edits the root/end chain, model-space target and pole,
influence, and FABRIK iterations/tolerance. Apply validates the complete edit before replacing
it. Blue target and purple pole handles preview a drag; release creates one Undo step, and
Escape cancels. The existing Animation Graph remains the base-pose canvas.

Create/Open an `.animmod` under project Assets. Save is explicit; Undo/Redo share the same
revisioned draft across UI, agents and developer Tools. Dirty IK resources are excluded from
automatic Save All, just like animation libraries. Save, then **Bind IK to Scene** with an
open scene model. Marker IDs are authored scene IDs, not node names or runtime entity IDs;
marker offsets are local to the marker. The Inspector restores existing scene bindings and
their offsets when selecting a model/constraint. With no marker ID, **Override Target Point**
and **Override Pole Point** edit instance-specific model-space points; disabling an override
uses the resource point. Reload scene bindings if the scene revision changes before applying.
The asset preview uses resource model-space points. Scene
bindings use a snapshot of current local transforms and reject targets within any animated
rig. Paused clips and LOD continue to respond to moving markers. Missing markers skip IK.

`modifierInspect`, `modifierCreate`, `modifierApply`, `modifierSample`, `modifierSave`,
`modifierUndo`, `modifierRedo`, `modifierPreview`, `modifierBind`, `modifierReload` and
`modifierDiscard` use `AnimationAuthoringRequest`. Edits require `expectedRevision`; binding
also requires `scenePath`, `entityID`, `sceneRevision` and a saved compatible resource.
`modifierOperations` contains add/remove/move/update commands. `modifierBindings` contains
instance-local target/pole overrides. The same read/write/preview/document permissions and
bounded asynchronous job transport apply to real API 2 Tools and the editor agent.

IK limits: 1 MiB per `.animmod`, 32 modifiers, 64 segments per chain, 1–64 iterations, and
32,768 segment-iterations per stack. There is no stretching, general joint-limit system or
end-effector orientation lock. Read `solverError` for the full-strength solve and `reachError`
for the actual influenced endpoint. Iteration exhaustion is an approximate result. Numerical
samples and successful binding do not prove pixels; inspect the shared viewport and Play.

Native 2D weighted deformation, spline-chain editing and typed timeline animation of IK
parameters are subsequent implementation stages; this 3D workflow does not establish them.


Copy `Examples/StudioTools/IKHelper` into project `Tools` to try the actual API 2 Tool.
Set the model and `.animmod` paths. Create, Poll, then Inspect, Poll. Copy a valid contiguous
three-bone set of stable IDs from the native Inspector or agent binding response into Root,
Middle and End. Add Two-Bone IK, Poll, then Sample, Poll. Save, Poll before binding. Set
model and marker entity IDs in an open scene, then Bind, Poll. Open the IK asset before
Preview. A failed/stale job requires a fresh Inspect; each terminal Poll consumes its result.
