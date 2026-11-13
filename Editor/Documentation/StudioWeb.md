# Ada Studio Web

`Editor/WebUI` is the default browser editor: a small React/DOM shell with native
text inputs and inset floating panels over a full-width viewport. The full-height
assistant sits on the left, with scene objects and the inspector on the right.
The bottom console reads the current AdaPlayer log stream and viewport diagnostics. Both the scene viewport
and Play use the fixed `AdaWebPlayer` in one isolated iframe; the editor does not
draw a separate scene in SVG, Canvas or another renderer. Opening a project starts
AdaEngine asynchronously while the DOM controls remain available. There is no
user Swift compilation, native process runner, ACP subprocess, SourceKit or
credential-store dependency in the browser target.

## Playground entry point

The DOM WebUI now starts with the Playground library. Its rail has Games, Create,
My projects and Account. Games reads the public `/v1/catalog` independently of
Studio sign-in and AI availability; an empty catalog is shown honestly. Create
uses the existing assistant and 2D/3D templates, and My projects opens private
Cloud workspaces. Generated tag artwork lives under `WebUI/assets/playground`
and is included in the ordinary frontend export.

Opening a project restores the project tools in the rail. The Ada mark returns
to Games and My projects opens the private list. Both paths wait for save, retain
the document/undo/selection/Player and use the existing recovery dialog on failure.
The library starts without automatically opening the last project. Create and My projects share an aligned mascot welcome layout with localized actions.
Signed-out, loading, unavailable and genuinely empty workspaces have distinct
states; an existing project list is never replaced by example content. Public game
launches use a separate tab (or the native Ada Studio link); they do not replace
the current editing document. Publishing controls remain a separate boundary.

Rebuild `Editor/WebUI` and refresh `/studio/` to see this interface. The standalone
HTML design preview and the Cloud website build are separate artifacts; changing
one does not update WebUI. Hosted deployment still needs an explicit rollout.

Optional assistant workflows are discovered by typing `/` in the composer.
The compact completion menu filters commands as you type; Enter/Tab inserts a
command into the editable draft, while Escape dismisses it. Only Send starts the
agent. Explicit workflow commands can appear anywhere in the request.

## Modules and boundaries

- `Editor/StudioCore` owns portable values, project snapshots, scene operations,
  document transactions/undo, source templates, bounded ZIP interchange and the
  platform service protocols. Native Studio uses its scene value codec and runtime
  capabilities; its existing workbench remains the native editor.
- `Editor/WebUI/src` owns the DOM interface, document transactions, ZIP interchange,
  cloud/recovery controller and browser agent loop. It consumes the existing
  portable snapshot/scene/API contracts; it does not import native Swift tooling.
- `platform.js` provides HTTP/SSE, IndexedDB and download; `preview.js` owns the isolated engine bridge.
- `Editor/Web` retains the previous AdaUI/WASM editor (`AdaEditorWeb`) as an
  optional legacy export, including its explicit publishing/release UI. Publishing
  controls have not yet been ported to the DOM shell; local testing has them disabled.
- `studio-player.js` runs on a separate HTTPS origin. It accepts only the
  configured Studio origins and mounts source snapshots into the fixed player's
  virtual filesystem. No Cloud token or provider key is part of that payload.

The Editor/Code/Game tabs share one document. File and scene tools use the same
transactions as manual changes. Undo preserves the conversation. Scene preview
installs component schemas without running gameplay systems; Game runs gameplay.
The inspector edits authored component values, including position/quaternion/scale.
Unknown runtime components fail with a diagnostic before scene entities spawn.

### 2D meshes in the browser Player

The browser Player renders the same 2D mesh component that Studio authors, `AdaSprite.Mesh2D`. Add it to an entity
that also has a Transform, and use an orthographic camera:

```json
"AdaSprite.Mesh2D": { "mesh": "Circle", "size": 200, "color": { "red": 0, "green": 1, "blue": 0, "alpha": 1 } }
```

| Field | Values | Default |
| --- | --- | --- |
| `mesh` | `Quad` or `Circle` | `Quad` |
| `size` | Edge length or diameter in world units; finite, above 0 and at most 100 000 | 64 |
| `color` | `red`, `green`, `blue`, `alpha` | white |

The mesh is drawn with a flat-color canvas material. `Cube`, `Sphere` and `Plane` belong to the 3D mesh component
and are rejected on a 2D mesh. An invalid `mesh`, `size` or `color` fails scene loading with a diagnostic before any
entity spawns. One minimal scene, a red quad beside a green circle, is the browser check in
`Tests/WebGolden/SAGAMesh2D`; run `node script/web_golden_saga.mjs <bundle> --mesh2d` against an exported player.
Scene selection uses the object hierarchy or viewport bounds picking; the inspector edits supported transforms,
materials and camera properties. Move/rotate/scale gizmos update the live world during
a drag and commit one document transaction on release. Escape/pointer cancellation
restores the original transform. Translation supports global/local axes; rotation
and scale use local axes. Ctrl enables positional/15-degree/scale snapping.
Scene changes replace the world inside the running
Player, retaining its WASM instance, GPU device and browser window. Editor mode uses
an ephemeral copy of the authored game camera and the same renderer with gameplay scripts, physics and autoplay
disabled. Play recreates the world from the same source snapshot with gameplay on;
Stop restores the authored scene. Readiness is acknowledged after an actual completed
GPU frame. Failed updates show engine diagnostics, and older queued updates cannot
mark a newer document revision ready. The SVG layer contains only gizmo handles and
selection bounds projected with actual AdaEngine matrices; all scene pixels remain
AdaEngine output. Camera/light entities are selected through the hierarchy. Meshes,
models and sprites use bounds picking (sprite transparent pixels are not filtered).
An edit overlapping a newer document/agent revision is discarded and reloaded.

Right-drag looks around; right-drag + WASD/QE flies (Shift is faster). Alt-left-drag
orbits the selection, middle-drag or Q pans, the wheel dollies/zooms, and F/double
click frames the selection. Reset returns to the authored game view. Navigation
never changes project cameras or enters undo; Play always uses authored cameras.
Studio captures pointer gestures and forwards bounded coordinates/revisions to the
isolated Player; dragging across panels does not lose the gesture. Expand Scene
hides panels until the toolbar button or Escape restores them.
Tools and navigation hints are available from the viewport toolbar. Duplicate
retains children and remaps their parent IDs. Delete removes the selected subtree.

The Code tab uses CodeMirror with an AdaScript tokenizer, syntax colors, line
numbers, bracket matching, indentation and Ctrl-F search. Code edits and undo use
the same document as scene/agent edits; a selection becomes assistant context.

The side rail navigates sections of the open project: overview (Home), scene,
assets, code and assistant. Assets have their own section instead of covering code.
The project title and save status stay visible. Switching sections retains the
document, undo, selected object, code editor and isolated Player instance.

All Projects is a separate action. It waits for cloud save before opening the
project list, which offers Continue for the open project. Selecting that project
returns to the existing document; opening another project reads its cloud snapshot
and pending IndexedDB recovery. On save failure the user can stay, retry, export a
ZIP or explicitly save a local draft and leave. The latter waits for a successful
IndexedDB transaction; storage failure keeps the project open. Local recovery is
scoped to this browser/device and cloud reopen currently requires a connection.
The browser's unload guard protects unsaved cloud changes and active agent work.

## Local development

Use the real Cloud services for project creation and persistence. A static server
cannot handle `/v1/workspaces` or sign-in. From `Editor/WebUI`, run
`npm run dev:setup` once, then `npm run dev`. The isolated stack serves Studio at
`http://localhost:8080/studio/`, normal Cloud sign-in at `/cloud`, and email codes
at `http://127.0.0.1:28088/`. It keeps PostgreSQL, Redis, Kafka and mirrored S3
objects in ignored local state. See [WebUI development](../WebUI/README.md) for
prerequisites, the separate Player export, ports and restart checks.

## Export

Use Swift 6.3.2 with its `swift-6.3.2-RELEASE_wasm` SDK on Linux/macOS (WSL on
Windows), plus the pinned Tint host tool:

```sh
cd Editor/WebUI
pnpm install --frozen-lockfile
pnpm test
pnpm build
cd ../..
python3 script/export_studio_web.py --output dist/studio-web \
  --studio-origin https://cloud-test.adaengine.org
```

The command copies the DOM build to `studio/` and exports `player/` using the existing
`export-web` plugin. `--legacy-wasm-editor` additionally builds the older AdaUI shell
instead of the DOM frontend. `--prepare-only` installs entrypoints into existing
exports; `--ui-dist` selects an already built DOM bundle. For frontend-only edits,
run `pnpm build` and `python3 script/prepare_studio_frontend.py --output dist/studio-web`
without rebuilding Swift. The helper removes non-runtime debug/name custom sections
from the player and writes `AdaWebPlayer.wasm.gz`; configure the static server to
serve precompressed gzip files with `Content-Encoding: gzip`. The helper verifies/prepares Tint and propagates the
selected Swift toolchain to plugin subprocesses. Each allowed Studio origin needs its own
`--studio-origin`. `ADAENGINE_YAMS_PACKAGE_PATH` can select an already prepared
WASI dependency; otherwise the helper creates a pinned private Yams copy with the
WASI binary64 precision constant. It never rewrites shared dependency checkouts.

Serve `studio/` at `/studio/` on the API origin. Serve the fixed player on a
separate HTTPS hostname, with `studio-preview.html` as the preview URL (a different
port on the Cloud host would still share host cookies). See the Cloud
repository's `docs/studio-web.md` for service/database/environment configuration.

Web Player **runtime API 4** and community source package **API 2** are separate
contracts. Do not compare or substitute their numbers.

## Saving, recovery and agents

Cloud snapshots include source files, assets and chat. Autosave sends an expected
server revision; a conflict creates a separate project copy. IndexedDB stores
pending changes, scoped by account and project. Restoring a checkpoint creates a
new revision. ZIP export contains editable portable sources, never authentication
settings. Import creates another project identity. ZIP import accepts stored and
deflated entries and validates paths, sizes and CRCs.

The provider registry is controlled by Cloud. Models without tools are unavailable
to the agent. Ada AI uses the existing credit reservation/settlement API; BYOK
passes the ephemeral in-memory key to the Cloud provider proxy. Neither mode sends
credentials to the player. Generation stops advancing when the tab closes; an
already submitted upstream response may finish server-side solely to settle its
actual cost. Interrupted tool calls are not blindly replayed on return.

### Shared agent workspace and A2UI

The browser agent uses the native Studio workflow sources: the build exports all
19 bundled skills, the native A2UI prompt as `ada-chat-ui`, offline documentation,
API declarations and complete example sources. Read them through `editor.skills.*`,
`editor.docs.*`, `editor.api.describe`, `editor.components.describe` and
`editor.examples.*` (provider function names replace dots with underscores).
Project workflows in `.ada/skills/<id>/SKILL.md` and root AGENTS/DESIGN/PLAN/PROGRESS
notes are portable project reference data, never host authorization.

The assistant offers per-project conversations, persistent drafts, selected skills,
file/image context, progress, tool results and token usage. A turn stays with its
originating conversation if the user opens another chat. Plan mode omits mutating
tool schemas; Ask mode pauses document changes for an explicit per-tool decision.
Closing the tab cancels the client loop. Incomplete forms/requests require an
explicit continuation rather than replaying edits after reopening.

The 35 browser tools include file search/patch, revision-checked scene batches,
project configuration, selection, Player diagnostics/frames and asset generation.
Sprite, sound, model and voxel scripts execute in the fixed WASM Player using
the native bounded generators and PNG/WAV/GLB/VOX writers. Assets enter the common
document transaction and undo path. WAV/GLB inspection reports measured metadata;
it does not establish audible playback or visual correctness.

A2UI v0.9.1 forms use the native Ada forms catalog: Text, Row/Column, TextField,
Toggle, ChoicePicker, Slider and Button. JSONL frames stream into escaped DOM
controls. Graphs, bindings, checks, ownership, generation and session are validated;
invalid updates preserve the last valid surface and return correction feedback.
Ordinary actions send the native action envelope back to the originating agent
without clearing the user's draft. Local color/spawn/apply actions require a
matching scene revision and commit the scene plus durable card Undo in one
transaction. Export goes through native AdaA2UI in the Player to a real `.ui`
source under `Assets/UI/AgentPreviews/`; the browser opens that source in Code.
It does not contain the native visual UI Designer.

Assistant chrome uses the shared English/Russian catalogs and
`AdaEditor.language` preference values. The browser preference is stored locally,
outside project exports; assistant settings switch the mounted UI. Agent/user
content, code, paths and protocol fields retain their original language.

The header's Annotate button enters a project-element picker. Choose a hierarchy
object, an object in the native viewport, or a component of an A2UI form; describe
the change in the anchored popup, then Add to composer. Notes accumulate in the
current conversation's saved draft with stable numbers. Selection remains active
after Add so several notes can be collected and sent in one request. Click a
numbered chip or a current viewport pin to reopen its popup and edit the note;
saving replaces its composer block while preserving its number and other notes.
Viewport pins only persist for the current selection session because camera
navigation invalidates their screen positions. Picking a
form button never executes it, and viewport picking never starts a gizmo gesture.
Escape cancels the popup. Context chips remove their note without overwriting
manually edited text. Neither selection nor Add invokes the provider.

Scene targets carry the entity ID/path/transform; A2UI targets carry surface and
component IDs plus bounded definition/value context. Canvas UI uses a marked
Player frame and normalized point rather than a semantic native UI hit tree.
If a scene object sits behind the HUD, the popup's target selector can explicitly
choose Game UI element. Capture is confined to the isolated game canvas; editor
settings/credentials are not annotation targets. Frames are sent only to vision
models, with a visible notice for text-only models. At most eight notes and four
images enter a request. The final composer text, including manual edits, is the
instruction; original popup text is not replayed as a second instruction.

Native ACP processes, shell/SwiftPM, SourceKit-LSP, external MCP, native Git,
network search, TestWorld simulation and publication tools are explicitly absent
from the browser host. Their shared workflow text is reference material, not an
implementation of those capabilities. No ChatGPT/Codex OAuth was added.

The retained legacy publishing UI captures a source snapshot, checks Pro and uses the existing upload,
validation and moderation pipeline. An agent cannot call publication. Draft saves
do not alter approved releases. Public release activation uses the existing
approved-release rollback API.

## Validation

```sh
swift test --package-path Editor/StudioCore
ADA_CLOUD_ONLY=1 swift test --filter 'StudioProvider|Workspace'
```

The second command belongs in the Cloud checkout. Its workspace integration suite
requires a disposable PostgreSQL database, Redis and private S3-compatible storage;
see the Cloud guide. Run `script/validate_webgpu.sh` with a compatible native
Swan/Dawn configuration and build native Studio after shared-code changes.

The browser release gate also requires real WebGPU frames, keyboard/text input,
2D/3D scene edits, recovery/conflict handling and an end-to-end publication in the
test environment. Compilation or deterministic provider fixtures alone do not
establish live-provider, audio or hosted moderation acceptance.

Local verification results and remaining hosted release gates are recorded in
[StudioWebValidation.md](StudioWebValidation.md).

For local development only, the editor and isolated player may use HTTP on
different loopback hosts (for example `localhost` and `127.0.0.1`). Hosted
previews still require HTTPS on a distinct hostname. Set
`STUDIO_PUBLISHING_ENABLED=false` in Cloud to hide publication/Pro controls
while testing project editing.
