# Terrain sculpting

Open a scene in the native Studio workbench and click **Terrain** in the viewport
toolbar. Studio switches to 3D and opens the brush controls in the **Inspector**.
The viewport keeps its full height. Modes use two rows of buttons; radius and
strength each have a full-width slider. **Create Terrain** in the Inspector adds
a centred 64-unit square with 65 × 65 height samples and selects it.

Choose **Raise Ground**, **Lower Ground**, **Smooth Ground** or **Flatten Ground**,
set the radius and strength, then hold the left mouse button and drag over the
terrain. The blue ring follows the surface. Holding still continues the brush;
moving quickly resamples the stroke. Flatten uses the height where the stroke
started. Strength is applied with elapsed time. Right-drag still rotates the
camera. Selecting a regular transform tool leaves terrain mode.

Each completed stroke is one scene-history edit. Escape cancels the current
stroke. Save, reopen, Undo and Redo use the ordinary scene document path. Terrain
samples live in the `AdaScene.Terrain3D` component; the generated mesh is transient.
The Inspector exposes the patch size, ground colour and collision toggle below
the contextual brush settings. Brush settings follow the active scene, disappear
in Play or when leaving terrain mode, and return when terrain mode is enabled.

`Model3DPlugin` installs `Terrain3DSystem`, which rebuilds the mesh when the height
field changes. When `Physics3DPlugin` is present, the same triangle grid creates a
static collider. Collision includes the authored entity and parent transforms;
the editing viewport omits physics. Removing the component removes its generated
mesh and collider. Native scene loading and native AdaScript export retain the
Codable component.

The tool edits authored height fields, not arbitrary imported meshes. A height
field has one height per X/Z point, so it cannot make caves or overhangs. It is a
single patch with a maximum resolution of 257 × 257; texture painting, terrain
streaming and browser-shell authoring are separate features. The shared native
workbench includes touch input, but phone and VR interaction are not established
by the desktop checks.

Coverage: `EditorTerrainTests` checks geometry winding, brush falloff and modes,
triangle picking, malformed data, scene round trips and stroke transactions.

Windows validation (2026-10-28): all 14 terrain and localization tests passed,
including the mounted 300-pixel Inspector, live English/Russian switching, mode
and creation actions, Play/tool visibility, and viewport ownership changes.
The updated Standalone package passed its bundled-tool startup checks. Earlier
packaged D3D12 validation rendered the authored terrain; scene Play created its
static collider with `PhysicsBody3DInitialized`. These checks do not establish
browser, phone or VR interaction parity.
