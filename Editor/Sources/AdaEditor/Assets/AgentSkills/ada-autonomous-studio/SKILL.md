---
name: ada-autonomous-studio
description: Build a complete, verified game from a brief in Ada Studio. Clarify the idea, write a design document with acceptance criteria and a file layout, split it into plans with art and sound right after the playable core, implement, and loop through build, play and checks until every criterion is met, without stalling on a check that cannot run. Use when the user asks for a whole game, an autonomous run, or "make me a game that...".
allowed-tools: editor.project.context, editor.skills.list, editor.skills.read, editor.docs.search, editor.docs.read, editor.examples.list, editor.examples.read, editor.scene.get, editor.scene.apply, editor.build.start, editor.task.status, editor.output.read, editor.play.start, editor.runtime.start, editor.runtime.step, editor.runtime.inspect
---

# Ada Autonomous Studio

This workflow turns "I want a game like this" into a finished, checked, playable result with as little back-and-forth as the brief allows. It wraps `ada-game-builder` (load it with `editor.skills.read` for the playable-loop and verification rules) and the asset workflows. For a single feature, bug or tweak to an existing game, use `ada-game-builder` alone; do not start a design process for small work.

Three files carry the state between steps and sessions. Keep them in the project's existing notes location, or `Design/` when there is none, and always read them before doing anything else in a returning session:

- `DESIGN.md`: what the game is and how we know it is done.
- `PLAN.md`: milestones and tasks, as a checklist.
- `PROGRESS.md`: what was done, what evidence exists, open problems and decisions.

## Start card (read this, then act)

Do these five steps in order. The first line of code comes after step 4, and within about ten read-only calls of the start.

1. **Context once.** Call `editor.project.context` and copy the facts you will need (roots, build system, destination, plugins, available tools, which verification tools exist) into `PROGRESS.md` under "Facts". Read them from there afterwards; never repeat a discovery call (`editor.project.context`, `editor.skills.list`, `editor.docs.*`, `editor.api.describe`, `editor.components.describe`, `editor.examples.list`) for something already in "Facts".
2. **Read only the required skills.** Required now: this skill, `ada-game-builder`, `ada-coding` (code layout) and the asset skills the design needs: `ada-sound-design` always, plus `ada-pixel-art` (2D) or `ada-procedural-models` / `ada-voxel-models` (3D). Everything else on demand, when the task first needs it: `ada-scene-authoring`, `ada-ui-forms` (HUD), `ada-build-run` (first build), `ada-visual-verification` (first frame), `ada-assets`, `ada-3d-assets`, `ada-3d-materials`, `ada-3d-animation`. Do not read all skills up front.
3. **One research pass.** `editor.examples.list` with the genre words ("3D game", "side scroller", "flappy", "runner", "2D platformer"), `editor.examples.read` the closest example once (for a 3D side-scroller or runner: `side-scroller-3d`; copy its file layout and idioms, not its numbers), and `editor.docs.search` for "AdaScript gameplay recipes". Do not search engine sources for syntax; the example and recipes carry it. Note the useful facts in `PROGRESS.md`.
4. **Write the three notes.** `DESIGN.md` (with the file layout, the palette and the sound table), `PLAN.md`, `PROGRESS.md`, before any game code.
5. **Build M1, then M2.** Playable core on primitives, then the art and sound milestone, each ending in its check (see Plan).

### Hard limits against stalling

- **Reads before writes:** at most about 10 read-only calls in a row. At the tenth, write something (code, a note, a scene edit) or decide to proceed with what you know.
- **Attempts per check:** at most 3 attempts to get one verification to work (a build, a frame capture, a simulation). After the third, stop trying that way.
- **Blocked verification is not a blocked project.** If a way to verify is unavailable or fails because of the tool, host or environment (not because of the game), record it in `PROGRESS.md` under "Blockers" as `blocker:` with what you tried, and in the acceptance table as `manual:` with exactly what a person should try. Then continue with the next milestone or task. Never spend a milestone on a check.
- **No repeated discovery** (see step 1) and no re-reading a skill you already read; its rules are in your notes.
- **Do not stop to ask** for anything the design lets you decide.

## 1. Recover

Call `editor.project.context`. Read the three files if they exist and resume from the first unchecked task; do not restart a design that exists. Look for existing scenes, scripts and assets and reuse them. If the project already holds a different game than the request, ask before changing direction.

## 2. Clarify (one round)

Ask once, in one message, only what would change the game materially, at most five questions, each with a suggested default so a short "ok" works: perspective and dimension (2D or 3D), the core challenge and how a round ends, controls and target platform, art style, and how long or large the first version should be. If the brief already answers a question, do not ask it. If the user says to decide or does not answer, record your choices as assumptions in `DESIGN.md` and continue. Do not ask again later unless a blocker needs a decision only the user can make.

## 3. Design document

When the brief names or implies a genre, load `ada-genres` and the matching `ada-genre-*` skill first: its defaults feed the camera, rules, content counts and acceptance criteria; joined genres also need `ada-genres-mashups`, and an undecided look needs `ada-genres-art-direction` for the art direction section.

Write `DESIGN.md` with these sections, short and concrete:

1. **Pitch**: one sentence, and the player's fantasy.
2. **Core loop**: the repeated action, challenge and reward; how a round starts, ends (win, lose) and restarts.
3. **Controls and camera.**
4. **Rules and numbers**: speeds, health, scores, timers, difficulty steps.
5. **Content**: levels, enemies, items, with counts for the first version.
6. **Art direction**: dimension, style, grid or unit scale, a fixed palette (list the colors), sprite sizes. Every generated asset follows this.
7. **Audio direction**: a table of sounds (name, trigger, character such as "short rising blip") and whether there is music.
8. **UI**: HUD fields, menus, game-over and restart.
9. **Technical choices**: project language and runtime, scene layout, plugins and input actions, and the **file layout decided before the first line of code**: a table of path and responsibility following `ada-coding` (one responsibility per file, folders `Components`, `Systems`, `Rules`, `Config`, `UI`, `Tests`, `Generators`; balance numbers in `Config`; size limits; no `Main`/`Game` catch-all file), the system order, and the test plan. For Swift projects also write the same rules into the project `AGENTS.md`. Update the table whenever the layout changes.
10. **Scope and non-goals**: what is deliberately left out.
11. **Acceptance criteria**: a numbered list of observable statements ("pressing space makes the player jump and the jump sound plays", "touching an enemy shows Game Over and R restarts with score 0"). Each ends with how it is verified, using the weakest sufficient method: *build* (compiles, no diagnostics), *validate* (scene, asset or model validation), *simulation* (logic stepped with inputs), *play frame* (screenshot of visible Play at a stated moment), *measurement* (asset metrics from `editor.audio.inspect`, `editor.model.inspect`), or *manual* (needs a human: how it feels, how it sounds). A criterion that can only be checked by hand is marked *manual* from the start.

## 4. Plan

Write `PLAN.md` as milestones, each a vertical slice that ends in something that runs and in a check. Art and sound sit right behind the core, not at the end, so the content and polish milestones are built on the real look and sound.

- **M1, playable core**: input, movement, the main challenge, an outcome and restart, following the file layout from `DESIGN.md`. Primitives and placeholder shapes are fine here, and only here. Exit check: it builds, and the core loop is exercised (simulation or a frame).
- **M2, art and sound** (immediately after M1, before content): choose the palette and style from `DESIGN.md`, generate the minimal asset set and wire it in: the player, the main obstacle or enemy and the ground or backdrop (`editor.sprite.generate`, `editor.model.generate`, `editor.voxel.generate`, tiles via `editor.tileset.create`), and **3-6 sounds** (`editor.audio.generate`: for example action, success, failure, plus UI and ambience) attached through `AudioSource` entities and played by a system. Exit check: assets validate or are measured (`editor.audio.inspect`, `editor.model.inspect`), the scene references them, and the game builds and runs.
- **M3, content**: levels, enemies, items, difficulty steps.
- **M4, interface and polish**: HUD, menus, feedback, game feel, camera, final balancing, the acceptance pass.

Each milestone lists its goal, tasks as `- [ ]` checkboxes small enough for one verified step, the assets it needs, and an exit check naming the acceptance criteria it completes. Order tasks so each one can be built and checked on its own.

**Do not plan "primitives" or "silence" as the final state when generators are available** (check "Facts"). The only allowed reasons are a non-goal written in `DESIGN.md` ("no audio: reason") or a missing tool recorded in `PROGRESS.md` as a blocker. If a milestone check cannot run (see the limits above), write `manual:` and start the next milestone; a stuck check never holds the plan.

## 5. Execute

Work one task at a time and keep the loop tight:

1. Implement the smallest change that does the task. Reuse existing assets, scenes and scripts. Follow `ada-coding`, `ada-scene-authoring` and the other workflows for the kind of work; read docs and examples with `editor.docs.search` and `editor.examples.read` instead of guessing engine APIs.
2. Check it: diagnostics, scene and asset validation, then build (`ada-build-run`). Read errors fully before fixing and revalidate after every fix.
3. Exercise it: step the simulation where the host offers it, and run visible Play with a frame capture for anything visual (`ada-visual-verification`).
4. Record it: tick the task in `PLAN.md` and add a line to `PROGRESS.md` with what changed, the files, and the evidence (which check, what it showed).

When a check fails, change the cause rather than the check. After three failed repairs of the same problem, stop repeating: try one different approach, and if it still fails record it in `PROGRESS.md` as a blocker (or `manual:` when only the check is out of reach) and move to work that does not depend on it. Keep files within the layout and size limits as you go: split a file that outgrows them in the same step. Ask the user only for a decision that you cannot make from the design. Never delete or rewrite acceptance criteria to make them pass; if one is wrong, change it explicitly in `DESIGN.md`, note why in `PROGRESS.md`, and continue.

## 6. Produce assets with the right tool

Generate what the design lists, in the style and palette of `DESIGN.md`, reusing before creating. Choose the palette (a short list of colors) once, before the first asset, and give every generator the same colors. Keep each file purposeful: do not keep near-duplicates. Keep the generator sources in `Generators/` (as `.txt`) so assets can be regenerated.

| Need | Use |
| --- | --- |
| Sprites, icons, characters, items, UI pieces | `ada-pixel-art` (`editor.sprite.generate`), then `editor.atlas.pack` or `editor.tileset.create` |
| Tile sheets, tile sets and levels | `ada-pixel-art` for the sheet, `ada-assets` for `editor.tileset.*` and `editor.tilemap.*` |
| Sound effects and short loops | `ada-sound-design` (`editor.audio.generate`), checked with `editor.audio.inspect`, played with the `AudioSource` component |
| 3D props, scenery, blocky objects | `ada-procedural-models` (`editor.model.generate`) or `ada-voxel-models` (`editor.voxel.generate`) |
| Textures and materials | `editor.texture.render` for patterns and flat PBR maps; `editor.image.generate` when a provider is configured; `ada-3d-materials` |
| Existing models | `ada-3d-assets` (`editor.model.import`); `editor.store.*` for the asset store |
| Scenes, entities, components | `ada-scene-authoring` |
| HUD, menus, forms | `ada-ui-forms` |

Not available yet: finished music and voices (they need an audio generation provider), organic or rigged character models and skeletal animation. Use short generated loops for music, and block-style or sprite characters, and say so in the report instead of faking it. Silence is a choice that must be written in `DESIGN.md`, not a default.

## 7. Accept

When the milestones are done, walk the acceptance criteria one by one. For each, run the verification named in the design and write the result and its evidence in `PROGRESS.md`:

- ✔ with the evidence type (build, validate, simulation, play frame, measurement).
- ✘ with what is wrong; add fix tasks to `PLAN.md`, return to step 5 and repeat the pass. Do at most three full acceptance passes unless the user asks for more.
- *manual*: list it as not verified with the exact thing a person should try.

Keep these evidence classes apart: compiling is not gameplay, simulation is not rendering, a frame is not sound, and measured audio is not heard audio. Do not mark a criterion verified by a method that cannot show it.

## 8. Report

Finish with: what the game is and how to run it, the controls, what was built per milestone, the acceptance table (criterion, result, evidence), what is not verified or missing (including features waiting on a provider), and sensible next steps. Publishing, purchases and account actions need explicit authorization and are not part of finishing the game.
