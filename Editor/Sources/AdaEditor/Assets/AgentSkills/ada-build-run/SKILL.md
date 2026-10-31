---
name: ada-build-run
description: Configure named build targets, startup scenes, Debug/Release settings and source selection; build, test, run, stop, and diagnose Ada projects on their supported destination.
allowed-tools: files.read, files.write, terminal, editor.project.context, editor.docs.read, editor.build.start, editor.test.start, editor.play.start, editor.task.status, editor.task.stop, editor.output.read, runtime.pause, runtime.resume, runtime.step_frame, trace.status, profiler.live_snapshot
---

# Ada Build and Run

- Use `editor.project.context` to check which project and document are open before choosing a build or run command. The editor MCP exposes project context and scene authoring; use the existing build/run workflow for compilation and tests.
- Prefer `editor.build.start`, `editor.test.start`, and `editor.play.start` to use the editor's selected destination and native AdaScript/SwiftPM flow. Poll `editor.task.status`, then read the `editor` or `game` output stream with `editor.output.read`.
- Use `editor.task.stop` for a running build, test, run, debugger, player, or Play Mode session.
- Save dirty documents before starting a build or run.
- AdaScript-only projects build in process and may run on macOS or iPadOS. SwiftPM build, test, and run is a macOS workflow in AdaEditor.

## Named build targets

Read `.ada/project.json`: `buildTargets` contains named configurations and `activeBuildTargetID` selects one by its stable `id`. A target is separate from a platform/run destination and from a SwiftPM executable product. A project without targets uses its existing top-level settings; preserve those when creating its first target.

- On shared desktop Studio, use the toolbar target picker next to the platform and **Edit Build Targets…**. Create or duplicate a target, set its scene, configuration, destination, arguments and file/resource selection, then **Save Build Targets**. Save activates the edited target; Cancel discards the draft. Stop active builds, games, debugging, deployment or recording before switching. The final target cannot be deleted.
- Use separate targets for a test scene and the main game rather than repeatedly replacing the game's entry. An open scene tab is not the product entry: `editor.play.start` with `mode: "scene"` runs that scene, while `mode: "product"` verifies the selected project target.
- Each target contains `id`, `name`, `build`, `run`, `runtime`, `startupScene`, `resourceRoots` and optional `product`. Keep IDs stable, names nonempty and unique ignoring case, and `build.system` consistent across targets. `build.configuration` is `debug` or `release`.
- Activation copies the selected target's `build`, `run`, `runtime`, `startupScene` and `resourceRoots` into top-level `build`, `run`, `runtime`, `editor.startupScene` and `paths.resourceRoots`. For a scene entry, update both target `runtime.entry.scene` and `startupScene`. Ordinary Project Settings saves capture the top-level settings back into the active target.
- Desktop MCP has no dedicated target mutation tool. If editing JSON through available file tools, preserve unknown fields and unrelated targets, capture outgoing top-level settings into the old active target before switching, and update the new active ID and all projected fields together. Changing only the ID or only the target array leaves the actual build on stale settings. Save documents and reload the project after external edits; verify the target and destination before running.
- Source include/exclude entries are project-relative file or directory prefixes, not glob patterns. An empty include list includes all project sources; exclusions win. Keep imported project sources included. Library dependencies remain available; source filtering does not remove scene/assets from export. Resource roots are shared through the active target's projection.
- Project identity, input actions, engine paths and AI settings remain shared. Host compiler/SDK paths belong to **Settings → Build & Export**, separately from named project targets. Selecting a platform does not add export support to the installed Studio.

For the full workflow and direct-file editing invariants, read `editor.docs.read` with `id: "BuildExport"` (repository source: `Editor/Documentation/BuildExport.md`). Browser and dedicated phone screens do not expose the target editor; use the host's actual capabilities. Older Studio bundles may lack this article or named-target support.

Validate the saved project with the installed `adastudio validate --project <path> --format json`, or the editor build flow. The CLI's `--target` option chooses an export platform, not a named target. Then run the product and inspect its startup scene/output. Report configuration validation and actual runtime verification separately.

## Testing an AdaScript project

`editor.test.start` runs AdaScript tests in process, with no SwiftPM. Write a test as a free function marked `@test` (optionally `@test("display name")`) with no parameters, either beside the code in any `.ada` file (sees that file's `private` names) or in a file under `Tests/` (sees public names only, never shipped).

Files under `Tests/` see public names only and must import what they use, with a trailing semicolon: `import { Flight } from "../Sources/Main.ada";`. A missing import fails the run with `Tests/X.ada:3:10: 'Flight' is declared in 'Sources/Main.ada'; import it with ...`.

```swift
@test("flap lifts the bird")
func flapLifts() {
    var f = Flight();
    f.tick(0.016, true, false);
    expect(f.y > 0.0);
}
```

- Assertions: `expect(cond)`, `expectEqual(a, b)`, `expectNear(a, b, tolerance)`, `expectNil(x)`, `fail(message)`; they record a failure and the test continues. `require(cond)` records and stops the test. Use `TestWorld()` (`spawn`, `insert`, `read`, `count`, `run(ticks)`, `runSystem(System, ticks)`, `advance(seconds)`) to test systems against a fresh ECS world.
- Do not keep state in module-level variables across tests: numbers, booleans, strings and null are restored after each test, but lists and maps are shared.
- Pass `filter` (a substring of the function name or display name) to run a subset. A project with no `@test`, or a filter that matches nothing, is refused or fails with that reason; it is not a pass.
- Poll `editor.task.status`: `status` is ready when every test passed and failed otherwise, and `adaScriptTests` has `passed`, `failed`, `total`, `finished` and a `failures` list. Then read `editor.output.read` (`editor` source): one `PASS`/`FAIL` line per test, each failure followed by `path:line:column: message` pointing at the failing assertion. A compile error in any source or test file fails the run with its location.
- Each test has a 30 second limit, checked at function entries and loop iterations; a runaway loop fails that test with "timed out" and the rest still run.
- The result is evidence of logic only. Passing tests do not prove rendering, input feel or audio; combine with `editor.play.start` and visual verification.
- Prefer the narrowest build or test that exercises the changed path, then broaden when the change crosses modules.
- Read structured diagnostics and complete output before editing again. Separate code failures from toolchain, network, storage, or platform failures.
- Stop an existing run before replacing its runtime state. Report the exit or stop reason.
