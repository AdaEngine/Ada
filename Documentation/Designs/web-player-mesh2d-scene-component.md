# Web Player: 2D mesh scene component

Status: **Approved by the user in chat on 2026-11-13; amended the same day (Studio capability list).**
Classification: improvement of the existing Web Player scene format (not a new subsystem).
Related: [WESL built-in shader migration](wesl-builtin-shader-migration.md) (slice 2: mesh2D and canvas materials).

## Problem

Ada Studio authors a 2D mesh as the scene component `AdaSprite.Mesh2D` (`mesh`, `size`, `color`; descriptor in
`EditorMeshComponentDescriptor.swift`). The Web Player scene decoder (`Tools/AdaWebPlayer/PlayerSceneComponents.swift`)
has no case for it, so a Studio scene that contains a 2D mesh does not play in the browser. This is a functional gap
on its own, and it also leaves `ColorCanvasMaterial` and the `mesh2d` WESL variants unreachable from any browser test.
The WASM canvas-material path (variant WGSL prelinked by the exporter) therefore has no end-to-end render evidence.

## Scope

In scope:

- Decode `AdaSprite.Mesh2D` in the Web Player with the same payload Studio writes:
  `mesh` (`Quad` or `Circle`; default `Quad`), `size` (finite, > 0, ≤ 100 000; default 64 to match Studio), `color`
  (default white).
- Build the component exactly as Studio does: a generated mesh with one `CustomMaterial(ColorCanvasMaterial(color:))`.
- Reject invalid payloads before any entity is spawned, using the existing `invalid(...)` error path, so a bad scene
  still fails as a unit.
- Add a 2D browser golden fixture that renders a canvas mesh, and a Studio-compatibility decode test.

- Amendment (human instruction, 2026-11-13): make Studio's Web Run accept the component. Studio validates scenes
  against `StudioRuntimeCapabilities.components` (`Editor/StudioCore/Sources/AdaStudioCore/StudioScene.swift`) and
  rejects `AdaSprite.Mesh2D` before the player sees it. Add the component to that set and to the browser field list in
  `EditorAgentWebContract.swift` (`mesh`, `size`, `color`), then regenerate the checked-in native agent contract
  (`Editor/WebUI/assets/agent-contract.json`) with `Editor/scripts/export-web-agent-contract.py`, because its source
  fingerprints cover these files. The snapshot was already stale before this change.

Out of scope:

- `Cube`, `Sphere`, `Plane` on `Mesh2D`: Studio does not offer them for 2D, and the player rejects them with the
  existing "Unsupported mesh primitive" style error.
- Other canvas materials (`CircleCanvasMaterial` is internal to AdaRender), custom 2D materials and Shader Graph
  materials on 2D meshes.
- Any change to the 3D mesh path, to Studio's 2D mesh authoring, or to the scene file format.

## Behavior and ownership

- Owner: `Tools/AdaWebPlayer` (`PlayerSceneComponents`). The 2D branch keeps its own two-primitive switch; the 3D helper's five-way switch is a different set, so sharing
  it was dropped as a refactor. No engine module changes are needed: `Mesh2DPlugin` and `SpritePlugin`
  are already installed by the player.
- The component keeps Studio's required companions (`Transform`, `Visibility`); the scene already supplies them.
- Rendering uses `ColorCanvasMaterial`. On WASM it now loads the exporter-prelinked WESL variants (see the
  slice 2 change in `CanvasMaterial.swift`); this feature adds the first browser evidence for that path.

## Alternatives considered

- **Test-only hook in the player** that spawns a mesh from code: rejected, it adds an untested-in-production code
  path and does not fix Studio scenes failing in the browser.
- **New component name** (for example `AdaWebPlayer.CanvasMesh`): rejected, it would fork the scene format from Studio.
- **Support all five primitives in 2D**: rejected, Studio does not offer them and they have no 2D meaning.

## Platform and compatibility impact

- Browser (WASM/WebGPU): new decode path; existing scenes without `Mesh2D` are unaffected.
- Native: unchanged. Studio: Web Run now accepts the component; authoring is unchanged. The payload is already
  Studio's own format, so no migration is needed.
- Scenes with an unknown component name already fail the player's decoder; behavior for them is unchanged.

## Acceptance criteria

1. A scene with a `Quad` and a `Circle` `AdaSprite.Mesh2D`, an orthographic camera and a known color renders those
   shapes in the Web Player; the 2D golden frame comparison passes in Chromium with WebGPU.
2. Payload validation: non-finite, zero, negative or oversized `size`, an unsupported `mesh` value, and a malformed
   `color` each fail scene preparation with a clear message and spawn nothing.
3. A payload produced by Studio's own `makeDefaultPayload` decodes in the player without edits.
4. The existing 3D SAGASmoke golden and Studio shader-graph smoke still pass.
5. Evidence recorded: host tests, browser golden result, and the platforms actually exercised. Mac/Metal and
   Android are not exercised by this change and are reported as not covered.

## Test plan (Red → Green → Refactor)

- Red: a decode test that feeds the Studio default payload for `AdaSprite.Mesh2D` and currently fails (unknown
  component). Red tests for each invalid payload in criterion 2.
- Green: add the decoder branch. The planned primitive-generation refactor was dropped (see Behavior and ownership).
- Browser: new fixture `Tests/WebGolden/SAGAMesh2D` run through `script/web_golden_saga.mjs --mesh2d`. It asserts
  saturated red pixels only on the left half, saturated green only on the right half and a black background, instead
  of a recorded reference image (this removes the open question about recording the reference).
- Validation lives in `AdaWebPlayerMesh2D` (`AdaScriptCompilerCore`) so it is host-testable; the player is an
  executable that needs a live renderer. Malformed `color` stays with the existing color decoder.
- Studio: a StudioCore test requires the component in `StudioRuntimeCapabilities.components`.

## User documentation delivery

- Added a "2D meshes in the browser Player" section to `Editor/Documentation/StudioWeb.md`, next to the existing
  discussion of scene components: payload table, limits, rejected primitives and the browser check.
  (The first draft named `BuildExport.md`; that guide covers build settings, so the component list belongs in the
  Studio Web guide.)
- Navigation: the guide is already part of the editor documentation; `update-offline-documentation.py --check`
  verifies the offline snapshot.
- Example check: the fixture scene `Tests/WebGolden/SAGAMesh2D` is the documented example and runs in Chromium.

## Resolved decisions and findings

1. Keep Studio's default `size` of 64: yes (the fixture sets its own size).
2. No recorded reference image: the browser check asserts colors and positions.
3. Browser evidence found three engine defects that blocked any canvas mesh from rendering with WESL variants; all
   three are fixed in this change with tests:
   - the 2D mesh pass compiled the material's legacy sources instead of asking it for its variant module
     (`Mesh2DSystem.swift`);
   - generated-WGSL reflection reported size 0 for every struct uniform (`WGSLReflection.swift`);
   - the WESL `ColorCanvasMaterial` named its uniform `material`, so the material's color writes never reached the
     buffer (`color_canvas_material.wesl`).
4. `CircleCanvasMaterial` addressed its three uniforms by member name (`u_Fade`, `u_Thickness`, `u_Color`), but the
   material storage finds a buffer by its block name, so those writes never landed (also under the old GLSL path).
   It now writes one `Parameters` struct under the block name `CircleCanvasMaterial` (32 bytes, `color` at offset 16),
   and the WESL variable carries that name. Layout and naming are pinned by host tests. The browser Player does not
   use this material, so there is no browser render evidence for it.
