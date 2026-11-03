# Assets, Animation and Shader Graph

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

### Assets and animation

Spine 4.2 `.skel`/`.spine` assets have a native 2D preview with clip/skin
selection, Play/Pause and bone overlays. Import/drop carries the atlas and pages;
JSON exports are imported as `.spine`. Add to Scene and the Spine Character 2D
template store a portable `SpineSource` component with playback/bone settings.
Imported 3D skins also have a Show/Hide bones overlay in the asset viewer and
3D scene viewport (edit and Play). `EditorSkeleton3DPlugin` installs the drawing
system after scheduler setup; the overlay follows the current skeletal pose.
See [Spine2D.md](../../Documentation/Spine2D.md). Skeleton/keyframe authoring and public
player/export integration are separate. Coverage: `EditorSpineTests` and
`SpineSceneTests`; native validation must exercise the Studio viewport.

Image preview includes a shared texture Inspector with sampler filters/wrap/LOD,
CPU-generated mip levels, Color/Normal/Data purpose, sRGB/Linear settings, and
2D/Cube import from a six-face horizontal strip. Apply persists an adjacent
`.texture.json`; preview selects applied levels/faces. Existing Play resources
require reloading. Guide: [TextureSettings.md](../../Documentation/TextureSettings.md).
Coverage: [EditorTextureSettingsTests.swift](../../Tests/AdaEditorTests/EditorTextureSettingsTests.swift).
Texture-atlas editing, tile-source (`.tileset`) editing, and
tile-map (`.tilemap`) painting/erasing, layers, pan and zoom.
Tile sources author light-occlusion polygons visually; tile maps select cells to
inherit, disable or replace their shadow shape. Shapes and sparse overrides
persist into scene Play while static atlas rendering remains chunked.
Coverage: [EditorTileOcclusionTests.swift](../../Tests/AdaEditorTests/EditorTileOcclusionTests.swift).
Tile-source bulk creation skips fully transparent cells, respecting margins and
spacing; individually authored tiles remain available.
Tile-map layer controls and the tile palette live in the contextual Inspector,
sharing the active document's model with the full-width canvas.
The Inspector also authors all eight brush/selected-cell tile orientations.
Canvas previews retain rectangular cell dimensions; layered resources preserve
orientation IDs. AdaScript can enqueue orientation changes to existing tiles.
Coverage: [EditorTileOrientationTests.swift](../../Tests/AdaEditorTests/EditorTileOrientationTests.swift).
The tile palette adapts its column count to the Inspector width and builds only
rows near the visible scroll viewport.
GLSL source editing and shader highlighting. Audio assets have Listen/Pause/Stop
and a preview volume slider; WAV files decode through the engine's real audio
resource path with independently owned preview output and gain. Opening a file does not autoplay. Leaving its tab cancels loading
and stops playback; headless runs keep the engine's output disabled.
Generic assets retain metadata previews. Coverage: `EditorAudioAssetPreviewTests`.
Scene keyframe clips have timeline/curve modes, tracks, keyframe values/timing,
interpolation and repeat modes. This is distinct from skeletal-animation tooling.

Model previews support orbit, middle-drag pan and right-drag look with WASD/QE
flight and Shift acceleration. Frame Model restores the view. Two opposing,
shadow-free lights and the bundled baked studio IBL keep all sides visible.
Navigation does not modify imported nodes. Coverage: `EditorModelPreviewNavigationTests`.

GLB/glTF models have a dedicated 3D preview with fitted framing, imported
mesh/material/skin counts, named clip selection and Play/Pause. Add to Scene
places a portable `Model3DSource` reference in an open scene, retaining the
original scale and selected clip settings. Imported Model 3D templates and
the Model 3D inspector picker also support this path. Imported hierarchy and
PBR materials appear in edit and Play, with independent animation players and
child-to-authored-entity picking. glTF imports copy local buffers/textures as a
collision-free bundle. Save/reopen, duplicate and scene undo/redo retain references.

MagicaVoxel `.vox` files are model assets too (`EditorModelResource.extensions`). Import
and drop copy the file as is (no dependencies); the preview reports frame count and
rate, and its Play/Pause drives the voxel clock (`VoxelAnimationPlayback3DComponent`)
as well as skeletal clips. The Model 3D inspector adds `voxelSize`,
`voxelMergeStatic` and `voxelFramesPerSecond`; they decode into
`Model3DSource.voxel` (nil while all are default) and reach the importer as an
asset query through `Model3DSource.assetPath`. Scene loading uses `assetPath` too.
glTF-specific tooling (agent model tools, texture assignment) uses
`EditorModelResource.gltfExtensions` and rejects `.vox`. Community packages still
accept only glTF models; adding `.vox` there needs a content validator.

Model preview and the selected model's Animator include skeletal graph authoring:
clip/blend/additive nodes, connections, bone/subtree masks and clip event markers.
Graphs preview through the production model renderer and save as structured
`Model3DSource.animationGraph` scene payloads in one undoable transaction.
Scene Animator adds Seek, preview transport, autoplay and latest-event display.
This authors pose graphs; imported skeletal keyframe and retargeting tools remain
separate gaps. See [AnimationGraphs.md](../../../Documentation/AnimationGraphs.md).
Coverage: [EditorAnimationGraphTests.swift](../../Tests/AdaEditorTests/EditorAnimationGraphTests.swift).

Entry points: [EditorModelAssetPreview.swift](../../Sources/AdaEditor/UI/Editor/EditorModelAssetPreview.swift),
[EditorModelAssetImporter.swift](../../Sources/AdaEditor/EditorModelAssetImporter.swift),
[Model3DSource.swift](../../../Sources/AdaScene/3D/Model3DSource.swift).
Coverage: [EditorModel3DTests.swift](../../Tests/AdaEditorTests/EditorModel3DTests.swift).

Entry points: [EditorTextureAtlasAssetEditor.swift](../../Sources/AdaEditor/UI/Editor/EditorTextureAtlasAssetEditor.swift),
[EditorTileMapEditorModel.swift](../../Sources/AdaEditor/UI/Editor/EditorTileMapEditorModel.swift),
[EditorKeyframeAnimation.swift](../../Sources/AdaEditor/EditorKeyframeAnimation.swift).
Coverage: [EditorTextureAtlasTests.swift](../../Tests/AdaEditorTests/EditorTextureAtlasTests.swift),
[EditorTileMapCanvasTests.swift](../../Tests/AdaEditorTests/EditorTileMapCanvasTests.swift),
[EditorKeyframeAnimationTests.swift](../../Tests/AdaEditorTests/EditorKeyframeAnimationTests.swift).

## Boundaries and incomplete paths

- Native Shader Graph includes typed graph/GLSL, Sprite and PBR materials,
  the AdaUI workbench editor and real AdaScript VM/AOT parameter bindings.
  Graph preview and editing controls live in the contextual Inspector. Search
  has a bordered search input and typed result rows; toolbar actions use visible
  icon buttons and parameter cards show selection. Color nodes have the native
  color picker and named RGBA channels; vectors use X/Y/Z/W fields.
  Source uses the shared read-only code editor with GLSL highlighting, line numbers,
  folding, selection/copy and workbench font/palette preferences; graph edits refresh it.
  Search overlays the canvas; canvas-local input updates after layout/zoom changes and
  supports middle-button panning over nodes/ports. Wires can be selected and
  deleted with Delete/Backspace or the context menu, with Undo. File trees and tabs use the
  Shader Graph icon. Coverage: `EditorNodeCanvasTests`, `EditorShaderGraphWorkbenchTests`,
  `EditorShaderGraphControlsTests`, `EditorShaderGraphSourceTests`.
  Export acceptance is incomplete: browser Player startup, packaged native
  playback, final device Play and performance checks remain. See
  [ShaderGraph.md](../../Documentation/ShaderGraph.md) and
  [ShaderGraphHandoff.md](../../Documentation/ShaderGraphHandoff.md) for current limits.
- Audio assets support explicit listening in their document tab and sounds play
  through the `AudioSource` component in Play. GLB/glTF
  import, preview, placement and clip playback exist; visual imported-material
  editing, skeleton editing and skeletal-clip authoring remain incomplete.
  The shared-workbench model preview has not established iPhone UI parity.
