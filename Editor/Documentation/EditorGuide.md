# AdaEditor Guide

Native control appearance follows the [Studio control design rules](Design/Controls.md):
visible action surfaces and states, themed fields, colored vector-axis badges and overflow indicators.

## Open or create a project

Use **Create new project** on the welcome screen, or choose **File > Open Project** to open an existing project. AdaScript projects use `.ada` source files. Projects with native Swift code also use Swift Package Manager.

## Explore and edit

The Project Navigator shows project files. Select a source file to edit it, or a `.ascn` scene to open the scene viewport. Use the scene hierarchy to select entities and the Inspector to edit their components. Use **File > New File** to create files and **File > Import Assets** to bring assets into the project.

Use **File > Save** to save the active document, or **File > Save All** to save all documents. The Code menu includes tab actions and editor font size controls.

## Import and place a 3D model

Use **File > Import Assets** or drop a `.glb`, `.gltf` or MagicaVoxel `.vox` into the project navigator.
Models open in a 3D preview with camera navigation, mesh/material/skin counts,
and a named animation picker with Play/Pause. Preview framing fits the model;
placing it in a scene preserves its original scale.

Open the destination `.ascn` scene, then open the model and choose
**Add to Scene…**. Select the destination from the open scenes. The new entity
stores a portable resource reference, so Save, reopening, duplicate and undo/redo
retain the model without copying imported nodes into the authored scene file.
The selected preview clip and playback setting become the entity's initial
animation settings.

Alternatively, add **Imported Model 3D** from the entity palette or add a
**Model 3D** component to an existing entity. In the Inspector, choose a project
model, enter a clip name shown in its preview, and set **Play animation** and
**Loop animation**. Imported nodes/materials are instantiated in both the scene
viewport and Play. Each placed model has its own animation player.

glTF imports with external buffers or textures are copied into a new model folder
with those dependencies. Keep dependencies beneath the source model's directory;
remote URLs and references escaping that directory are rejected. Missing files
fail the bundle import. Repeated imports create another bundle without replacing
the original. Imported materials are preserved. Imported meshes/rigs remain source
assets; editable animation clips are stored separately as described below.

## Edit bone animation

Select a Model 3D entity and open **Animator → Bone Keyframes**. Extract an editable
copy of an imported clip or create a clip from the rig's rest pose. Select bones,
tracks and timeline keys to edit translation, rotation, scale or morph weights.
Preview the model, use Undo/Redo, then explicitly **Save** the `.animlib` resource.
Autosave and tab switches retain animation drafts without writing them.
**Save and Bind** attaches a saved compatible library through the scene's own history;
the Skeletal Graph can then select its qualified clips. See
[Editing bone animation](AnimationAuthoring.md) for key commands, conflict recovery
and the shared agent/Studio Tools API. The offline **Authoring skeletal animation**
guide also covers Swift library construction and runtime graph references.

## MagicaVoxel models

A `.vox` file is imported and placed like any other model: it opens in the 3D
preview, **Add to Scene…** creates a **Model 3D** entity, and the model appears in
the scene viewport and in Play. A voxel file is self-contained, so import simply
copies it (repeated imports get a new name instead of overwriting).

The scene is imported as an entity hierarchy that keeps the MagicaVoxel node names
and transforms, so parts such as an arm can be picked and animated separately.
Keyframed transforms and models with several frames animate; the preview header
shows the frame count and rate, and Play/Pause controls the voxel timeline.
**Play animation** on the Model 3D component decides whether it starts playing.
MagicaVoxel is right-handed with Z up and the engine is left-handed with Y up,
so the import swaps those axes; a model keeps the look of MagicaVoxel's front view.

The Model 3D inspector has three voxel settings that apply to `.vox` sources only
and stay at their defaults for other formats:

- **Voxel size** (default 0.1) is the edge length of one voxel in world units.
- **Merge static voxels** merges parts without animation into one mesh. This lowers
  the draw count and removes hidden faces between parts, but merged parts can no
  longer be picked separately.
- **Voxel animation fps** (default 30) is the playback rate of MagicaVoxel frames.

Voxel materials are not imported yet: colors come from the palette and the model
uses one diffuse material. The model tools of the AI agent work with glTF only.

## Build and run

Choose **Build > Build Project** to build the project. **Build > Run** runs the active scene inside the editor when a scene is selected; otherwise it runs the selected target. **Build > Stop** stops the current operation. Build Output and Problems show progress and diagnostics.

## Settings

Open **Settings** for editor preferences and **Project > Project Settings** for project configuration. Project Dependencies and Swift Package Tasks are available in the Project menu.

## Read documentation offline

Choose **Help > AdaEngine Documentation** or use the **Documentation** button. These guides ship with the editor and are available without a network connection or an engine checkout. Search matches article titles and contents. Use the article list, section links, and Back and Forward buttons to navigate. Code examples and complete articles can be copied.

The offline library contains hand-written engine and AdaScript guides. Generated API reference pages and external websites are not included. External links are marked as requiring internet.

## Start scripting

Read <doc:GettingStartedWithAdaScript>, then <doc:AdaScriptLanguage> and <doc:AdaScriptECS>.


## Interactive agent forms

On macOS, ACP agents can stream native AdaUI forms and previews directly into
Agent Chat using the advertised A2UI catalog. Ask for an NPC configuration form,
edit the controls, and submit after the agent's turn finishes. The current values
return to the same conversation, and the agent can generate an editable preview.
**Open in UI Designer** creates a new `.ui` asset under `Assets/UI/AgentPreviews`;
refine it through the normal designer, undo/redo, and save workflow. Local form
edits persist with the chat. Invalid updates retain the last working form and
show an interface error; interrupted forms remain disabled until refreshed.
The separate iPhone chat path is not connected to these cards yet.
