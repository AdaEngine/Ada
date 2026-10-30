# Mobile agent feedback and reference tools

Mobile Studio hosts SloppyRuntime in process. The host advertises editor-owned tool schemas to both API and Codex providers and dispatches them on the UI actor against the current project. These operations use the embedded Gravity language core; iOS does not need to launch `gravity-lsp` or a compiler subprocess.

Mobile requests include short host rules, user instructions and a bounded catalog of enabled mobile skills. Full skill bodies, the detailed mobile workflow and the A2UI protocol are loaded on demand through `editor.skills.read`, rather than repeated in every user and repair prompt. `editor.skills.list` searches bundled workflows and enabled built-in/imported mobile skills. Imported skills use `mobile:<id>` IDs and remain readable from the saved run settings after the original Markdown file is removed; disabled skills are unavailable on subsequent runs. `mobile-studio-workflow` covers editing and verification, and `mobile-chat-ui` provides the complete A2UI contract. Existing saved prompt envelopes retain their chat presentation.

Start with `editor.project.context`. Search and read the bundled documentation with `editor.docs.search` and `editor.docs.read`. Use `editor.api.describe` for the current compiler catalog, and `editor.components.describe` for exact serialized component names, fields, required components and default payloads. `editor.examples.list/read` returns complete project files for movement/input, dynamic component systems and a multi-file 3D side-scroller (`side-scroller-3d`); `editor.examples.list` accepts a `query` such as "3D game", "flappy" or "runner". The "AdaScript gameplay recipes" article explains input, movement, spawning, collisions, score, restart and `AudioSource` patterns. These references work offline.

After writing files, run `editor.gravity.diagnostics`. It reloads the project workspace and reports project-relative paths and zero-based UTF-16 ranges. Completion, hover and definition take explicit paths and LSP positions. Use `editor.project.configure` for validated changes to `runtime.entry`, `runtime.plugins` and `inputActions`; arbitrary manifest writes remain unavailable.

`editor.build` compiles AdaScript and loads every scene under the configured assets directory, including nested scenes. Failures preserve complete compiler/loader text and include language diagnostics. `editor.scene.validate` can also inspect a selected scene. The mobile completion gate repeats this check, executes startup callbacks and eight simulation frames, and returns failures to the same agent session for up to two repair turns.

`editor.runtime.start` prepares an isolated world from the real build artifact. It installs transforms, input, scene navigation, scriptable objects and enabled physics, then runs startup systems. `editor.runtime.step` advances up to 120 frames at a requested delta and accepts the complete held keyboard set; an empty set releases all keys. `editor.runtime.inspect` returns entity positions, dynamic component values, script diagnostics, navigation errors and bounded logs. Restart after changes. `editor.runtime.stop` cancels script tasks and tears down input monitoring.

`editor.output.read` preserves build/debug errors in a bounded cursor-based journal and also reads current diagnostics from visible Play. Simulation failures return failed tool results with the complete snapshot, so the agent can inspect the offending state.

`editor.play.start` opens the actual mobile Play screen; `editor.play.inspect` reads its script diagnostics. Visible Play is independent of the isolated simulation.

Simulation verifies game logic and keyboard input. Rendering, audio, network transport, touch controls and hit testing require visible Play. The result payload states these verification limits. Portable AdaScript currently rejects `@view` and `@resource` declarations; the project context and documentation tools identify this restriction.

SloppyRuntime accepts host tool definitions at initialization and an allowlisted handler for each turn. Built-in file/build tools keep precedence. The default tool budget is 80 rounds, bounded to 200. Tool calls and results continue through the existing transcript/activity persistence path.

Debug Simulator builds accept `--mobile-agent-tools-smoke`. This runs the real portable executor and mobile bridge against an isolated temporary project, prints a `MOBILE_AGENT_SMOKE_REPORT` JSON record, and removes the fixture. It checks provider schemas, offline references, compilation, keyboard simulation, output and rejection of broken sources without using credentials.

## Internet tools

`editor.web.search` searches Brave Search's public HTML endpoint without an API key and returns up to ten titles, URLs and snippets. Provider rate limits, network failures and challenges produce tool errors; the agent can retry with another query or fetch a known URL. This public endpoint has no availability guarantee.

`editor.web.fetch` reads HTTP(S) HTML, text, JSON or XML with a title, final URL and up to 100 links. HTML scripts/styles are removed; JavaScript is never executed. Responses are limited to 2 MiB and returned text to 50,000 characters, with explicit truncation. Binary files should use download instead.

`editor.web.download` saves up to 16 MiB to an explicit project-relative destination under `Assets/` or `Downloads/`. Traversal, hidden files, symlink escapes and existing destinations are rejected. A staged file is moved into place only after a successful bounded request. Results include source/final URLs, MIME type and byte count; downloads do not execute or unpack files. Use `editor.asset.validate` before assigning downloaded resources.

These tools are advertised to mobile API/Codex providers through the existing host bridge, to desktop agents through the existing AdaMCP endpoint, and to the built-in native Ada AI through its project-scoped Cloud tool host. Ada AI's Ask/Plan modes allow search and page reading; downloads are available in Build mode through the existing project-change approval flow. Browser Studio has a separate tool registry and does not expose these internet tools.

HTTP uses ephemeral sessions without cookies or stored credentials, a 30-second request timeout and up to five validated redirects. URL credentials, local hostnames and private IP literals are rejected. Web content is untrusted reference data; cite its source and preserve resource attribution.

The opt-in `ADA_WEB_LIVE_SMOKE=1` test runs the production mobile dispatcher and URLSession transport through a Brave query, then reads and downloads `example.com` into a temporary project.

For Simulator bridge validation, launch a Debug build with both `--mobile-agent-tools-smoke` and `--mobile-agent-web-smoke`. The same portable executor invokes all three tools and checks saved bytes; the `MOBILE_AGENT_SMOKE_REPORT` includes their results. This optional mode requires internet access.

## Images and game resources

Selected, pasted and marked-up images are transmitted as actual image segments to both API models and Codex. Codex serialization preserves `input_image`; it does not replace pictures with file paths. Images are bounded to eight files, 8 MB each and 24 MB total, normalized to PNG for transport and persisted through the normal session attachment store. The composer shows cached thumbnails with individual removal controls. Plain text paste keeps its original behavior.

`editor.image.read` asks the configured vision model a question about a project image. `editor.image.generate` creates a PNG/JPEG/WebP through the project's image provider; supplying `source` edits a reference image. Generation uses a separate OpenAI API key, configurable in mobile Agent settings, or the existing API key when the selected API endpoint is OpenAI. Codex authorization handles image understanding. Enable/configure generation with `editor.project.configure` and an `ai.imageGeneration` patch. Provider responses are decoded before saving, and existing destinations are preserved.

`editor.texture.render` creates procedural PNGs offline: solid colors, checkerboards, gradients, seeded noise and flat normal maps. It accepts `specJSON` with bounded dimensions and RGBA color arrays. Use these as sprite, tile, albedo, normal, metallic or roughness texture inputs.

`editor.sprite.generate`, `editor.audio.generate`, `editor.model.generate` and `editor.voxel.generate` create a pixel-art PNG, a mono WAV, a low-poly GLB or a MagicaVoxel file from an AdaScript `func build(...)` that runs in an isolated VM with no file, network or scene access. They write a new file under the assets root (an existing path is refused) and return the `@res://` reference plus a summary: sizes and colors, parts and triangles, or audio measurements. `editor.audio.inspect` measures any WAV: peak and RMS in dBFS, clipping, silence, dominant frequency, brightness and a loudness envelope. The `ada-pixel-art`, `ada-sound-design`, `ada-procedural-models` and `ada-voxel-models` skills document the script APIs. Play a generated sound with the `AudioSource` component.

`editor.atlas.read/write/pack` manages native `.atlas` descriptors. Packing uses the same engine algorithm as runtime loading and returns named pixel regions and UV coordinates plus a PNG preview. Source paths remain editable.

`editor.tileset.create/read/edit` slices source images into a native `.tileset`, exposes stable source IDs and coordinates, and manages tile definitions and animation. `editor.tilemap.read/write/edit` validates palettes, stable tile references, cells and layers. Editing supports paint, erase, fill and new layers. Removing a referenced tile is rejected. Resource edits preserve existing fields and validate before committing.

`editor.scene.asset.assign` binds images, atlases and maps to registered component asset fields. Read `editor.components.describe` for exact field names. `editor.model.texture.assign` updates glTF/GLB PBR material channels while preserving geometry and binary chunks. Texture creation does not unwrap a mesh or bake lighting; model UVs still come from the model.

After edits, use `editor.asset.validate`, build, start visible Play, then `editor.play.capture`. Capture reads only a completed GPU frame and saves a project PNG for `editor.image.read`. Simulation results remain separate from visual proof.

## Desktop game verification

Desktop Studio sees the game through the game's own camera, not through the editor window.

- `editor.play.capture` (`cameraName`, `maxDimension`): waits for a completed frame of the running game and saves a PNG under `<project>/.ada/workspace/agent-captures` (newest 80 kept). It returns an explicit error when no game is running, the camera is not active, or the backend cannot read pixels.
- `render.capture_screenshot` returns the same game frame while Play runs. Without a running game it captures the editor window and says so in `world`; that image is not game evidence. `ui.capture_node_screenshot` keeps using the editor window.
- `editor.play.run_scenario` runs a timed input script against an isolated offscreen runtime of the AdaScript project (`target: "offscreen"`, default) or the running game (`target: "play"`). Steps are `{t,key,down|tap}`, `{t,mouse,down|tap,x,y}`, `{t,move}`, `{t,capture,camera?}` and `{t,snapshot}`. The result lists `frames` (PNG paths or per-frame errors), `snapshots` (entities and component summaries chosen with `watch`), `logs`, `diagnostics`, `errors`, `status` (`completed`, `timed_out`, `cancelled`, `failed`) and `manualChecks` for unavailable frames. Limits: 60 s, 400 events, 12 frames, 40 snapshots, 1280 px frames, 25 entities per snapshot, wall-clock deadline of duration plus 15 s.
- The offscreen runtime renders scene cameras only. `@view` HUD overlays and the Studio game toolbar are not part of it; use `target: "play"` to capture them. SwiftPM projects can use `target: "play"` and `editor.play.capture`; offscreen requires an AdaScript project.
- Timing is wall-clock. Verify direction, ordering and thresholds rather than exact positions, and keep needed values in `@export` fields of a scriptable object (snapshots list them under `scripts[].fields`). Script statics and `System.print` output are not readable.

Engine support: `SceneView.frameCaptureLabel(_:)` registers a view in `SceneViewFrameRegistry`; `SceneViewFrameSource` reads the latest completed frame (downscaled on request) and `OffscreenSceneRuntime` hosts a window-less scene. Games in Play use the label `game`.

## Background agent activity

On iOS/iPadOS 26, user-started mobile turns request `BGContinuedProcessingTask` while the app is active. The system Activity reports the project, current model/tool/validation phase, elapsed duration and the latest tool error. Progress counts completed operations; the dynamically discovered workload always has an outstanding unit until successful validation. Timer updates never advance progress.

The system can deny or expire background execution. A denied request continues in the foreground and records a warning under Activity. Expiration and system cancellation cancel the worker, finish the Activity exactly once, retain saved project files and record an interrupted result. Older iOS versions run in the foreground and display that limitation. This does not resume an agent after force quit.

The bell on the mobile projects screen opens Activity, persistent error/result history and system-notification preferences. Notifications require user permission; Live Activity for continued processing is managed by the system. On iPad the launcher’s Mobile agent button opens this workspace in a separate window.

Model requests, project files, compilation and `editor.runtime` simulation can continue in the background. Play rendering and GPU frame capture require the foreground and return an explicit error when unavailable. Automatic preview opening is skipped when validation finishes in the background.

Debug Simulator builds accept `--mobile-background-agent-qa` and the optional `--mobile-background-agent-qa-failure`. The diagnostic uses the same operation and system-background bridge, writes 45 verification records with UIKit application state to `Documents/background-agent-qa.txt`, and opens Activity. It uses no model credentials.

## Native 3D tools and shared knowledge

See [AI-assisted 3D work](Agent3DWorkflow.md) for `editor.model.inspect/validate/import/material.edit`, GLB/glTF validation through `editor.asset.validate`, and the shared desktop/mobile offline knowledge tools. `editor.skills.list/read` loads bundled 3D workflows on demand. The `basic-3d-scene` example includes a perspective camera, PBR cube, directional light and game3d configuration. Model validation is CPU import/profile evidence; visible Play and completed GPU captures remain required for rendering and clip playback.
