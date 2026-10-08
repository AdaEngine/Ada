---
name: ada-game-builder
description: Create or iterate on a playable 2D or 3D AdaEngine game in Ada Studio. Use for game ideas, complete prototypes, gameplay features, level design, controls, HUD, game feel, and gameplay bugs; load this workflow before implementation. General editor maintenance and non-game tasks use their own workflows.
---

# Ada Game Builder

Turn the user's request into a playable game using the current Ada project, supported engine APIs, and Studio's authoring tools. Keep the scope requested by the user. For an existing game, extend its design and conventions; do not replace it with a new template.

## Recover the project and choose the next slice

- Start with `editor.project.context`. Inspect the declared source/assets roots, build system, runtime entry, plugins, input actions, destination and available tools. Read existing project instructions and design/progress notes when present.
- Load `ada-project-orientation` and only the relevant companion workflows using `editor.skills.read`. Use `editor.docs.search/read`, `editor.api.describe`, `editor.components.describe` and `editor.examples.list/read` for current APIs, serialization and working examples. Never translate Unity, Godot or browser-engine API names into guessed AdaEngine calls.
- For a new game, establish the player's goal, repeated action/challenge/reward loop, controls, camera, failure or completion condition, and restart behavior. Infer reasonable defaults from a clear brief and state them briefly. Ask only about missing choices that materially change the result. A request for brainstorming or a plan stays in that mode.
- Choose a small complete playable slice. For a prototype, connect input, movement, challenge, feedback, outcome and restart before adding content or polish. For a feature or bug, define the observable behavior and exercise the affected path without restarting the whole design process.
- Keep useful continuation notes in the project's existing format for work spanning sessions: implemented behavior, paths, validation, unresolved issues and next step. Scale documentation to the task; do not make new planning documents or repeated confirmations prerequisites for an already authorized implementation.

## Build through Studio

- Preserve the project's language and build system. AdaScript uses the embedded compiler and runtime; Swift projects require a host/distribution with SwiftPM support. Use `ada-coding` and `ada-gravity-lsp` when applicable. User-facing language terminology is AdaScript.
- Check that the current host can create or open the required project before scaffolding. If a project is missing, use the available Studio project workflow or explain the exact setup needed. Do not silently switch to Phaser, Three.js or another engine.
- Keep authored entities, hierarchy, components, scripts, input actions and resources persistent. Desktop open-scene edits use `editor.scene.get/apply` with the latest revision and preserve undo; load `ada-scene-authoring`. A component replacement is a complete payload: retain fields not being changed. On a host without structured scene editing, use supported project file tools, preserve schema and unknown fields, and validate the result.
- Verify script attachment and runtime entry, required plugins, input-action mapping, resource references and gameplay collision shapes. A source file or imported model alone does not connect the gameplay path. Use validated project configuration tools when advertised.
- For 2D work, reuse native sprites, atlases, tile sources and tile maps. Inspect their schemas and existing project resources before writing. Check camera framing, draw order, anchors, collision geometry and scene scale in Play.
- For 3D work, load `ada-3d-assets`, `ada-3d-materials` or `ada-3d-animation` as needed. Start from the `basic-3d-scene` example when appropriate. Inspect model bounds, dependencies and clip names; place portable resource references, frame the camera, light the scene and author colliders separately. Studio's model tools do not provide rig or skeletal-keyframe authoring.
- Author HUD, menus and restart controls through the project's existing AdaUI or `.ui` Designer workflow. Inspect current bindings and script exports. AdaScript `@view` is unavailable; use the supported UI resource path rather than inventing a scripting UI API.

## Make the loop readable and responsive

- Show the objective and controls where the player needs them. Keep score, health, timer or progress legible and outside important play areas. Give clear success/failure feedback and make restart reset gameplay state, timers, spawned objects and input.
- Tune movement, collision response, camera and difficulty with the actual game running. Add feedback such as animation, particles, sound or hit reactions where it improves the requested experience; verify that the host and APIs support it.
- For touch destinations, share gameplay actions with desktop bindings and provide visible movement/action controls. Handle simultaneous movement and actions, release/cancel, safe areas and readable targets. Keyboard simulation cannot verify touch input.
- Reuse existing assets first. When creating or importing resources, load `ada-assets` or the relevant 3D workflow, validate them, connect their resource references, and check them in Play. Preserve source/license attribution for external assets. Use only generation providers actually configured on the host; unavailable generation should not prevent a prototype using suitable placeholders.

## Close the verification loop

Choose tools advertised by the current host; desktop and mobile tool names and capabilities differ.

1. Save through the supported document workflow. Run the narrowest diagnostics, asset/scene validation and build for the changed path. Desktop uses `editor.build.start`, `editor.task.status` and `editor.output.read`; mobile uses `editor.build` and `editor.output.read`. Load `ada-build-run` for the host's build/run flow. Read errors before repairing and revalidate after a fix.
2. Exercise gameplay logic where simulation is available. Mobile `editor.runtime.start/step/inspect/stop` can verify movement and state transitions with held-key sets; send an empty set to release input. Restart the simulation after edits. Check the changed behavior, boundaries, outcome and restart. Run existing focused tests where supported; AdaScript-only projects do not have a SwiftPM test path.
3. Start visible Play and load `ada-visual-verification`. Desktop uses `editor.play.start` and `render.capture_screenshot`; mobile uses `editor.play.start`, `editor.play.inspect`, `editor.play.capture` and `editor.image.read`. Inspect a completed rendered frame. Compare frames at different times for animation and exercise the actual controls when tools permit.
4. Keep compilation, simulation, rendered appearance, touch interaction and audio/network evidence separate. Headless simulation and CPU model import do not prove GPU rendering or gameplay feel. If foreground access, input automation or a required provider is unavailable, state the remaining check precisely; do not mark it verified.

Finish with the playable behavior delivered, the controls, exact validation performed and any remaining limitation. Keep repair work within the host's configured budgets. Publishing, purchases or external account actions require authorization for that action and are not implied by a request to build a game.
