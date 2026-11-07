# Ada Studio CLI game verification — PR Decomposition Map

- **Created:** 2026-10-24
- **Request:** Close the CLI gaps in project creation, running games, input, screenshots and gameplay scenarios.
- **Trunk:** `main`
- **Approval:** Approved by the user on 2026-10-24.
- **Implementation checkout:** `/Users/vlad-prusakov/.codex/worktrees/studio-cli-game-verification/AdaEngine`.
- **Size budgets:** Target <=600 reviewable added/removed lines per slice; cap 1000. Estimates include tests, exclude documentation and binary reference images.

## Evidence and scope

The existing CLI has strict parsing, JSON reports, cancellation, project validation
and export (`EditorCLI.swift`, `EditorCLIInvocation.swift`). `EditorAgentSimulation`
already executes AdaScript with physics, stepped keyboard input, logs and entity
snapshots. It explicitly excludes rendering and touch UI verification.

`EditorSceneViewScenarioHost.startOffscreen` already configures the production
runtime and renders scene cameras via `OffscreenSceneRuntime`. It supports key,
mouse and pointer events, completed GPU frames, snapshots and runtime logs.
`EditorPlayScenario` and `EditorPlayScenarioRunner` provide bounded timed replay.
The CLI must reuse these services rather than implement another game runtime.

Initial execution scope is saved AdaScript projects on standalone macOS.
SwiftPM games and exported Web/Android applications retain their existing build
paths; this map does not promise a universal runner for every exported target.
GPU capture requires an available render backend. Unsupported project/runtime
capabilities produce explicit diagnostics, not successful partial verification.
Scene-camera screenshots do not establish full HUD, audio or multiplayer coverage.

## Slices

| # | PR title | Purpose | Strategy | Budget | Depends on | Status |
|---|----------|---------|----------|--------|------------|--------|
| 1 | CLI bounded gameplay execution | `run` advances real AdaScript simulation with keyboard input and returns state/logs/errors. | Additive opt-in command | ~500 | — | implemented-local |
| 2 | CLI GPU screenshots | `capture` renders the real game camera offscreen and saves a completed PNG frame. | Additive opt-in command | ~550 | — | implemented-local |
| 3 | CLI scenario replay | `scenario` replays JSON input steps and gathers labelled frames, snapshots and logs. | Additive opt-in command | ~500 | 2 | implemented-local |
| 4 | CLI gameplay assertions | `test --scenario` evaluates explicit expectations and fails on runtime or assertion failures. | Additive opt-in command | ~550 | 3 | implemented-local |
| 5 | CLI project creation and acceptance example | `project create` produces a playable AdaScript project with an executable acceptance scenario. | Additive opt-in command | ~550 | 4 | implemented-local |

Names and exact flags below are proposed. Final CLI help and documentation must
match the implemented parser; each slice ships its own documentation and tests.

## Slice details

### Slice 1 — CLI bounded gameplay execution
- **In scope:** `run --project <path> --frames <count> --delta-time <seconds> --keys <held-set> --format json`; reuse the project builder and `EditorAgentSimulation`; bounded execution, cancellation and teardown; runtime diagnostics make the command fail; structured state in the report.
- **Out of scope:** Rendering, mouse/touch input, persistent cross-command sessions and external application control.
- **Ships safely because:** Only the new explicit command invokes the runtime. Existing CLI commands and mobile callers keep their behavior.
- **Verification:** Real temporary project; entity movement while a key is held; no movement after release; runtime error propagation; invalid arguments; interruption and resource cleanup. Do not equate state-only execution with visual proof.
- **Cleanup owed:** None.

### Slice 2 — CLI GPU screenshots
- **In scope:** `capture --project <path> --output <png>`, bounded startup and capture; reuse `EditorSceneViewScenarioHost.startOffscreen` and completed-frame readback; dimensions/camera selection; report backend, frame sequence and artifact path; explicit failure when no valid frame is available.
- **Out of scope:** Editor window screenshots, image recognition, new renderer backends and a claim of complete HUD/touch coverage.
- **Ships safely because:** Capture initializes rendering only on explicit invocation; ordinary validation remains window-free and does not initialize the renderer.
- **Verification:** Execute the CLI on a real small camera/sprite scene; decode PNG and inspect dimensions and expected pixels; exercise missing camera/resource and unavailable renderer failures. Run GPU suites sequentially.
- **Cleanup owed:** None.

### Slice 3 — CLI scenario replay
- **In scope:** `scenario --project <path> --scenario <json> --output <directory>`; reuse existing timed key/mouse/pointer, snapshot and capture actions; isolated game ownership; bounded artifacts and logs; timeout/cancellation; release held inputs on teardown; no attachment to an unrelated live Play session.
- **Out of scope:** New scripting languages, persistent remote control and automatic gameplay verdicts based on images.
- **Ships safely because:** The command creates and tears down its own runtime. Shared scenario additions remain backward compatible with existing MCP callers.
- **Verification:** Production scenario path with real input changing state; before/after PNGs and snapshots; invalid and out-of-limit scripts; failed captures, runtime errors and timeouts cannot be reported as an unqualified success.
- **Cleanup owed:** None.

### Slice 4 — CLI gameplay assertions
- **In scope:** `test --project <path> --scenario <json>`; versioned, typed expectations over labelled snapshots (entity existence/activity, numeric position/component/script state comparisons); expected/actual results; stable failure diagnostics and exit status; strict rejection of missing or ambiguous targets, unknown predicates and invalid values.
- **Out of scope:** Inferring game rules, visual aesthetics, arbitrary expression evaluation and guaranteed victory for arbitrary games. The author supplies acceptance conditions.
- **Ships safely because:** Assertions are an explicit CLI mode; MCP scenario replay retains its current evidence-collection contract. State needed for assertions is exposed through additive structured fields, not parsed presentation strings.
- **Verification:** The same real gameplay fixture must produce both a passing run and a deliberately failing assertion; missing entities/fields, script errors, truncated evidence and absent requested captures cannot pass silently.
- **Cleanup owed:** None.

### Slice 5 — CLI project creation and acceptance example
- **In scope:** `project create --project <new-path> --name <name> --template <supported-template>`; reuse project/template generation without recent-project or preference writes; refuse existing destinations; stage and commit creation atomically; provide a playable camera/player/input example and its acceptance scenario; document the full agent loop.
- **Out of scope:** Template marketplace, asset providers, publishing, signing and a separate generator with divergent project metadata.
- **Ships safely because:** Explicit creation writes only a new requested destination; shared template extraction preserves UI creation behavior and is covered by its existing tests.
- **Verification:** Actual executable creates a project, validates it, runs input, captures a GPU frame and passes its scenario; an intentionally broken acceptance condition exits unsuccessfully. Verify creation does not modify recents or overwrite existing files. Test the bundled standalone CLI when packaging permits.
- **Cleanup owed:** None.

## Integration choice

Recommended: additive commands that reuse the current services. Each command is
useful independently and activates only when invoked; no feature toggle is needed.
A toggle at `EditorCLI.execute` would add configuration and removal work without
protecting existing commands. A new runtime abstraction replacing editor/mobile
callers would increase risk and scope without helping this CLI extension.

## Working tree and delivery

The primary checkout has an unrelated untracked
`Tests/AdaEngineTests/StoreAnimationAcceptanceTests.swift`; preserve it. After map
approval, inspect attached worktrees and use a suitable isolated checkout for
implementation. Each slice gets its own short-lived `codex/` branch and reviewable
diff. Reconcile the map between slices; do not claim a planned command is shipped.
Publication, merge and push follow the user's authorization and draft preferences.

## Decision log
- 2026-10-24: Inspected CLI, simulation, project creation and production GPU scenario services. Proposed five additive slices. Existing replay services reduce scope; CLI expectations still require explicit implementation.
- 2026-10-24: The user approved the complete map. Began slice 1 on `codex/studio-cli-run` in an isolated worktree; tests pending. Remote publication is deferred.

## Completed implementation

All five slices are implemented and locally committed on `codex/studio-cli-project-create` in the attached worktree. The authoritative updated map and complete evidence are in `/Users/vlad-prusakov/.codex/worktrees/studio-cli-game-verification/AdaEngine/Documentation/Plans/2026-10-24-studio-cli-game-verification.md`.

Final verification: 46 focused tests passed, 14 real CLI invocations passed, Metal 2D/3D frames were checked, and new/changed lines pass SwiftLint. A real infinite loop was terminated by the external deadline. The 24 legacy project-store issues reproduce on original main. The installed app was not updated; no remote publication occurred.
