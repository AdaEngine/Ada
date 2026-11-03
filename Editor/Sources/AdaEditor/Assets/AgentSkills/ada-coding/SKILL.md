---
name: ada-coding
description: Implement and validate Swift, AdaScript, shader, and project-file changes in Ada projects, with a required code layout (one responsibility per file, layers, size limits, balance numbers in Config).
allowed-tools: files.read, files.write, terminal, editor.gravity.diagnostics, editor.gravity.completion, editor.gravity.hover, editor.gravity.definition
---

# Ada Coding

- Identify whether the project is AdaScript-only or SwiftPM-backed before selecting commands.
- Follow existing neighboring code, component registrations, plugins, and generated-source contracts.
- For AdaScript, use project diagnostics and the in-process AdaScript build. Do not invent Swift-only APIs.
- Keep AdaScript style diagnostics clean: spaces around binary operators and after
  commas/colons, one statement per line, and blank lines between types and functions.
  Read `editor.gravity.diagnostics` after edits and fix `adascript-lint` warnings
  before finishing. On desktop/CI run
  `adastudio validate --project <directory> --lint strict --format json` to reject
  style violations.
- For `.ada` and `.gravity` source, use the Gravity LSP skill and editor Gravity tools for diagnostics, completion, hover, and definitions. Keep Swift source on SourceKit-LSP.
- For Swift, use the project package model and the narrowest applicable build or test.
- Preserve unrelated edits and report exact validation scope. Build output is not proof of runtime behavior when the change affects rendering or interaction.

## Code layout (required for every new game)

Decide the layout before the first line of code and write it into `DESIGN.md` under "Technical choices" as a table of path and responsibility. Change the table when the layout changes. A game that is one big `Main.ada` (or `Game.ada`, `Game.swift`) is a defect; split it before adding more.

- **One file, one responsibility.** One `@system` class per file, named after it (`FlightSystem.ada`). One component per file, or a few closely related ones. No catch-all files.
- **Folders by layer.** `Sources/Config.ada` (or `Config/`), `Sources/Components/` (data only: `@component` structs), `Sources/Systems/` (behavior), `Sources/Rules.ada` or `Sources/Rules/` (pure functions with no ECS access), `Sources/UI/` (HUD scriptables and text), `Tests/`, `Generators/` (sources for `editor.audio.generate` and the other generators, saved as `.txt` so they are not compiled into the game; `Tools/` is reserved for Studio tools), `Assets/`.
- **Size limits.** A file stays under about 120 lines (split above 200), a function under 30 lines, a system's `update` under 40 lines. When a limit is crossed, extract a rule into `Rules`, not a comment.
- **Numbers and names live in `Config`.** Speeds, gravity, sizes, timings, spawn distances, phase constants and score steps are `Config.name`, never literals in a system. A literal is allowed only for 0, 1 and obvious axis math.
- **State lives in data.** Use `@component` for per-entity state and for shared round state (phase, score, best) on one "Game" entity read with `@query`; not script globals or `static var` caches. `@resource` structs work too and are bound with `@res`; every declared resource exists from the start, whatever `autoInsert` says. Prefer components when a scene should author the data or a test must read it, because `TestWorld` cannot read resources. Keep per-frame requests (input intent, sound cues) in small components so systems stay independent.
- **Order systems explicitly** with `@before(id:)`/`@after(id:)`. Only one system reads `Input` (bound with `@res(optional: true)` and an `available()` check); the rest read an intent component, which also makes the game testable.
- **Naming.** Systems end in `System`; components are singular nouns (`Player`, `Obstacle`); stable ids are `game.thing`; files match the type they hold.
- **Tests.** Put game rules in pure functions and cover them with `@test` in `Tests/`; run the schedule in `TestWorld` (it has no `Input`, so replace the intent component with `world.insert`). Read `editor.examples.read` with id `side-scroller-3d` once for this layout in a working game.

For Swift or SwiftPM projects apply the same rules through the project's `AGENTS.md`: create or extend it at the project root with the layer folders, the size limits above, where constants live, the build and test commands, and "no catch-all files"; then follow it. Targets and folders mirror the layers (`Components`, `Systems`, `Config`, `UI`).
