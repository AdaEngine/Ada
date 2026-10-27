# Shader Graph

Shader Graph authors `.shadergraph` materials for Sprites and PBR surfaces in the
native Studio workbench. Create a graph with New File, choose a template, and
open it from the project navigator. Sprite, PBR Surface, Dissolve and UV Scroll
templates are ordinary editable graphs. The browser Studio does not author graphs.

## Authoring

The canvas supports pan/zoom, Fit, multiple selection, dragging nodes, connecting
compatible ports, rerouting wires and dropping a wire on empty space to search
compatible nodes. Hold the middle mouse button to pan, including over nodes and
ports; the mouse wheel zooms around the pointer. Search opens over the canvas
without moving or resizing it and filters by name and connected type.
Click a wire to highlight it, then press Delete/Backspace or choose Delete in
the context menu. This removes only the connection; Undo restores it.
The workbench's contextual Inspector contains the preview, Add Node controls,
node properties, output settings and organization tools. The Inspector edits
node values, exposed parameter IDs/names, texture references and render settings.
Toolbar actions use bordered icon buttons; active Pan and Source modes are highlighted.
Search has an outlined input and separate result rows with value-type badges.
Parameter cards show the selected parameter and reveal its node on click.
Inspector sections separate preview, node creation, selection, output and graph tools.
Color values provide a native color picker plus labeled linear R/G/B/A fields;
vector values use X/Y/Z/W. Channel editing preserves fractional input and document history.
Select a node and expand its channels when an individual vector component is
needed. Groups and notes organize a graph; Copy/Paste remaps node/group IDs.
Layout and organization do not change compiled shader code.

Undo/Redo records one transaction per gesture. Save and Save All use the normal
workbench document path; split panes and restored tabs share the document model.
An unsupported schema, conflicting external edit or read-only file is preserved
and reported instead of overwritten. Source mode opens generated GLSL in the shared
code editor, using the workbench's font and syntax palette, line numbers, folding,
selection/copy and horizontal/vertical scrolling. It refreshes after graph edits
and Undo; generated code is read-only and does not become a separate saved asset.
English and Russian use the same persisted identifiers.

The preview uses the production renderer: Sprite, sphere, plane or the selected
imported model. Play/Pause, Restart and time nodes allow animated effects. Compilation
runs after a short debounce and diagnostics retain node/port identity. CPU compile
errors keep the last valid preview material. Backend failures appear in the
preview and runtime diagnostics. Save recompiles assigned scene materials when
resources are reloaded; existing Play resources require a reload.

## Materials

Assign a `.shadergraph` to a Sprite or a PBR material slot using the scene
Inspector. Each assignment has independent parameter values and texture overrides.
Imported model overrides are stored on `Model3DSource`, keyed by material index;
they do not modify the imported asset. Removing the assignment restores the stock
material path. Render settings cover opaque, mask (with alpha cutoff), blend and
double-sided surfaces. Masked PBR graphs share silhouette evaluation in shadow,
depth and motion passes.

Colors are linear RGBA. Numeric values must be finite and have the declared
component count. Float broadcasts are explicit; unrelated vector dimensions do
not silently convert. Texture references resolve relative to the graph document
or use `@res://` project resources. Time is world-relative; static graphs do not
update their uniforms for time. Swift can take clock ownership with `setTime`.

Nodes include constants, exposed parameters, textures/sampling, UV, sprite texture,
time, arithmetic, interpolation, clamps, comparisons, trigonometry, vector
construction and deterministic 2D value noise. Select Value chooses between two
typed inputs using a Bool parameter. Raw shader code, vertex displacement,
subgraphs and postprocess graphs are outside this version.

## AdaScript

Query systems must declare write access to change materials. A graph handle is
borrowed for the current invocation; do not store it in a field or use it after
that callback. VM and compiled AOT share the same validation and instance rules.

```ada
@system(id: "tint.effect", scheduler: "update")
@access(write: [Sprite])
class TintEffect {
    @query(Sprite) var sprites;
    func update(context) {
        for (var row in sprites) {
            var graph = row.sprite.shader(0);
            graph.setColor("tint", [1.0, 0.4, 0.2, 1.0]);
            graph.setFloat("amount", 0.5);
        }
    }
}
```

`component.shader(slot)` reads the assigned graph; Sprite uses slot `0`, Mesh3D
uses its material index. `component.assignShader(slot, "@res://Effects/Tint.shadergraph")`
creates an independent instance; an empty path clears it. Scriptable components
use the same calls on their declared `@component(Sprite) var sprite: Sprite;` binding.

`parameterIDs()`, `parameterName(id)` and `parameterType(id)` discover exposed
parameters. Stable IDs take precedence; a unique display name is also accepted.
Typed `get`/`set` methods cover Float, Bool, Vector2/3/4, Color and Texture.
`getValue(id, type)` and `setValue(id, type, value)` use the persisted type strings.
Readonly, expired, ambiguous, unknown and mismatched accesses report diagnostics;
setters return false. AOT rejects stale borrowed handles at its ABI boundary.

## Format and runtime

`ShaderGraph` is a versioned Codable/Hashable/Sendable value in AdaRender. The
asset envelope adds metadata outside the authored graph. Nodes/links use stable
IDs, named ports and typed values; lowering validates every authored node and
produces deterministic dependency order for reachable code. Cycles, missing IDs,
unknown operations, invalid literals and incompatible ports retain their location.

`compileGLSL()` produces code, parameter/texture bindings and a source map. Graph
resources use descriptor group 1 with numeric slots aligned to vec4. Material
instances share immutable code/pipelines while keeping values, clocks, textures
and immutable GPU snapshots independent. The stock render path remains available
when no graph is assigned.

Web export packages host-compiled WGSL and reflection in `shaders.shadergraphlib`.
The archive contains exact production fragment variants and graph documents;
resource preloading installs it before scene decoding. The browser never compiles
GLSL synchronously. Missing graphs, textures or baked variants fail explicitly.

**Export acceptance is still incomplete.** WASM packaging succeeds, but the
browser Player has an unresolved startup hang; native app packaging and the final
PBR export workflow need another run. See [the handoff checklist](ShaderGraphHandoff.md)
for reproducible fixtures, commands, known failures and the remaining release gates.

## Checks

Core suites: ShaderGraphTests, ShaderGraphProgramTests, ShaderGraphMaterialTests,
ShaderGraphEffectTests and ShaderGraphArchiveTests. ShaderGraphScriptTests runs
actual VM and compiled AOT fixtures, including readonly and handle lifetime rules.
Editor suites cover document history, canvas geometry/drawing, authoring, catalog,
search, clipboard, groups, focus and localization. `script/validate_webgpu.sh`
compiles fresh SPIR-V through pinned Tint and checks GPU frames against references.
See the [decomposition/evidence map](../docs/tbd/decompositions/2026-10-20-shader-graph.md)
for the separately recorded native UI, device, export and performance results.
