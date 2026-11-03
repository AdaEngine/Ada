# Windows Studio performance

Measure the Release executable on a visible, foreground window after startup and
shader compilation have finished. Compilation, screenshots and detailed CPU tracing
must not run during the FPS capture. Repeat with the same project, viewport,
window size and monitor for before/after comparisons.

## Reproduce

Build with `script/build_studio_windows.ps1 -Configuration release -Jobs 4`.
Launch the resulting `AdaEditor.exe`, or extract and launch the portable ZIP
produced by `script/package_studio_windows.py`.

Download the console application from the official
[PresentMon releases](https://github.com/GameTechDev/PresentMon/releases).
For PresentMon 2.6.0 x64, the SHA-256 used in this validation is
`b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af`.
Select the Studio PID (not another running Debug instance), then run:

```powershell
PresentMon.exe --process_id <PID> --session_name AdaStudioPerf --delay 5 `
  --timed 30 --terminate_after_timed --no_console_stats --output_file editor.csv
python script/summarize_presentmon.py editor.csv --output editor-summary.json
```

The script reads PresentMon's default hybrid CSV. It reports each swapchain
separately and excludes the first interval, whose previous frame lies outside
the capture. Present FPS, display FPS, p95/p99, worst intervals and intervals
above 25 ms are distinct metrics. Missing display/GPU data stays unavailable.
Do not add together FPS from multiple Studio windows. The reciprocal of GPU
busy time is not display FPS. See the official
[PresentMon console documentation](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md)
for metric definitions.

## Windows timing

### Text selection

Code selections no longer publish changes to the observed document array or run
the active-document callback. Commands obtain the current range and selected text
through the workbench's document snapshots. Caret geometry lives in a separate
observable object read by the completion overlay; moving it does not rebuild the
code view and recompute syntax spans.

Window dispatch coalesces consecutive left-button moves only while a text editor
owns an active selection drag. Press/release, modifiers, keys and window boundaries
remain ordered. Other drags retain every point, as does the raw input stream and
its scene-picking blocks.

`EditorTextInteractionPerformanceTests` mounts the production code view and checks
that changing the selection performs zero view rebuilds, preserves current command
snapshots and does not edit the document. It also exercises captured selection
through `UIWindow`, including input boundaries. The 26 focused Windows tests in
this suite, hover input, selection hints, file search, completion layout, scroll
indicators and split panes pass. This is UI work-count validation, not a displayed
FPS claim. Logs and capture experiments are in `.build-tools/text-interaction-perf`.

For displayed selection FPS, distribute mouse positions over time or capture
native input. A burst ending at the same position each frame becomes one visible
selection update after coalescing, so its present rate cannot establish smoothness
or be compared with the former intermediate redraws. Discard captures interrupted
by manual input, inactive windows, screenshots, startup or a crashed process.

On 2026-10-31, a foreground Release comparison used Last Autumn, a maximized
2560x1392 client, collapsed project tree and the same code font. A repeated
34-position selection scenario with 1 ms waits measured 20.89 displayed FPS before
and 52.10 after. Median display interval fell from 34.75 to 6.95 ms; p95 fell from
41.71 to 13.89 ms. These averages include gaps between automation requests.
A separate single continuous gesture with 480 positions recorded 340 frames over
2.55 seconds: 132.64 displayed FPS, 6.97 ms p95 and 13.88 ms p99. One 180.56 ms
interval remained, so this does not establish a steady 140 FPS guarantee.

Scrolling HordeSystem.ada with the same timed wheel scenario measured 27.41 FPS
before and 28.39 after, with p95 near 62.51 ms in both captures. These changes do
not resolve the scrolling bottleneck. The native Windows checks also verified
selection, wheel scrolling and Find prefilling `medkit` after a double click.
The text context menu opened and dismissed in both builds without a crash in this
run; the earlier native-window creation crash remains an unreproduced issue.
Captures, summaries and replayable scenarios are under
`.build-tools/text-interaction-perf/native-validation`.

### Camera navigation and annotation presentation

SceneView queues completed GPU frames; its annotations must describe the displayed
texture, rather than the latest navigation state. The viewport now records grid
and gizmo commands when a scene frame is scheduled and publishes that snapshot
with the texture at the next UI tick. GPU completion only marks the queued frame
ready, preventing a texture swap between UI extraction and submission. Resize
and shutdown discard pending snapshots with their targets; the displayed snapshot
scales with its texture while render-target resizing is pending.

Annotation Canvas nodes check their drawing revision synchronously, retaining
unchanged commands and tessellation without asynchronous view reconciliation.
3D rotation no longer rebuilds hidden rulers or unchanged status text. Marker
projection shares one camera matrix per annotation snapshot, and circular icons
use the existing ellipse primitive instead of tessellating paths.

The initial Skeletal Garden rotation reproduction recorded CPU frame p95 of
72.89 ms, with UpdateWindowManagerSystem p95 of 25.70 ms and UI tessellation p95
of 8.20 ms. This diagnostic capture includes tracing overhead and is not display
FPS. Its summary is `.build-tools/performance/viewport-sync-baseline-cpu.json`.

A subsequent foreground baseline used the default camera at `(0, 6, -10)`,
the maximized 2560×1032 client, a 1675×852 viewport, and a repeated right-button
rotation through the normal Main-world input path. With no compiler or detailed
profiler running, a 10-second PresentMon capture measured 40.81 ms mean displayed
interval, 65.83 ms p95 and 72.44 ms p99 (24.51 displayed FPS). The matched input
scenario and executable hashes are in `.build-tools/performance/viewport-sync-*`.
Post-change captures from inactive windows are discarded: the editor suspends
scene rendering while inactive, so those CPU timings cannot establish a speedup.

An active post-change CPU diagnostic during concurrent compilation measured
UpdateWindowManagerSystem p95 of 3.14 ms (the foreground baseline was 29.53 ms).
Its CPU frame p95 was 46.04 ms, but the background load and slightly different
camera pose prevent treating that capture as a controlled frame-time comparison.
See `.build-tools/performance/viewport-sync-after-background-build-cpu.json`.

At the user's request to leave other builds running, the final 10-second
PresentMon check ran with Windows/WSL compilation in the background. The active,
maximized Skeletal Garden window repeated the same default-camera rotation.
It recorded 23.26 ms mean displayed interval, 34.72 ms p95, 36.98 ms p99 and
43.90 ms maximum (42.99 displayed FPS; 427 measured intervals). This is a useful
post-change runtime observation, not an isolated before/after benchmark: the
baseline above had no compiler load. No detailed CPU profiler or screenshots
ran during this PresentMon capture. The executable was the subsequently staged
`standalone-studio/AdaStudio-exports-final-20261016-windows-x86_64/AdaEditor.exe`,
which includes the viewport fix and the concurrent export work.
Capture: `.build-tools/performance/viewport-sync-after-background-build.csv`;
summary: `.build-tools/performance/viewport-sync-after-background-build-summary.json`.

The Release product builds and opens Skeletal Garden. Twelve focused engine/UI
tests and thirty editor tests pass, covering out-of-order GPU completion,
synchronous annotation publication, retained commands, resized annotations,
camera transitions and transform interaction. The broader headless clipping and
depth-grid suites currently hit SPIRV-Cross's existing combined-sampler error
when loading text/sprite shaders; they are not counted as passing validation.
Logs: `.build-tools/viewport-sync-engine-verified-tests.log` and
`.build-tools/viewport-sync-editor-final-focused-tests.log`.

### 3D scenes in the 2D viewport

Skeletal Garden reproduced a steady 120.51 ms mean CPU frame in 2D mode,
including 103.27 ms mean in `UpdateWindowManagerSystem`. UI preview preparation
sorted every runtime entity and decoded authored hierarchy transforms before
checking for a `UIComponent`. This ran every UI update even in scenes without UI.
The preview now filters active authored UI entities first, returns immediately
when there are none, and sorts/resolves transforms only for UI candidates.

The foreground baseline used the same maximized 2560x1032 client and 1675x852
viewport, with a stationary orthographic camera. A separate 10-second PresentMon
capture during compilation measured 142.84 ms mean displayed interval and
182.60 ms p95 (7.00 FPS), while GPU busy time averaged 12.13 ms. Background
builds were left running as requested; these timings are observations under
varying system load, not an isolated benchmark. Baseline files are
`.build-tools/performance/viewport-2d-before*`.

The rebuilt Release editor reduced mean UI update work to 0.94 ms (1.18 ms p95)
in a separate detailed CPU capture; total CPU frame time averaged 30.22 ms with
tracing enabled. Without tracing, a 10-second stationary PresentMon capture
measured 27.53 ms mean display interval, 36.65 ms p95 and 36.32 FPS. A second
10-second capture while panning measured 29.45 ms mean, 41.33 ms p95 and 33.95 FPS.
Both used the same viewport, default 2D center and zoom 150. Input passed through
the normal Main-world mouse route, and a separate 120-pixel drag moved the camera
from x=0 to x=-0.8 as expected before returning to x=0. The editor stayed active;
the Android emulator and test compilation remained running. These are loaded
system observations, not a claim of steady 60 FPS. Captures/summaries are
`.build-tools/performance/viewport-2d-after*`; the staged executable is
`.build-tools/viewport-2d-package/AdaStudio-viewport-2d-local-windows-x86_64/AdaEditor.exe`.

Release and the editor test product build successfully. All 30 tests in the
viewport presentation, scene UI preview, gizmo and transform-interaction suites
pass. The file-backed UI preview case now runs with both zero and 539 additional
scene objects, including pan/zoom retention and removing the last UI entity.
Logs: `.build-tools/viewport-2d-release-build.log`,
`.build-tools/viewport-2d-tests-build.log`, `.build-tools/viewport-2d-focused-tests.log`.

### Previous Windows measurements

Hierarchy and project-tree hover state previously lived on the whole sidebar.
Moving between rows rebuilt the panel, including the hierarchy's scene/resource
projection. Row-local hover state and leaf drawing groups now retain unaffected
rows and their cached drawing commands. On Windows Debug, synthetic pointer events
through the production `UIContainerView` path reduced maximum rebuild counts from
91 to 10 for a 539-entity hierarchy and from 67 to 6 for a 600-file tree. Motion
within the same row performs no rebuild. A draw-command regression also verifies
that hovering one row changes only that row's cached layer revision. These are
UI work counts, not a native displayed-frame-time measurement.

Window input dispatch also coalesces consecutive button-free mouse moves before
delivering them to UI. Every raw event and its scene-picking block remains available
to scene consumers. Presses, drags, scrolling, keyboard input, modifier changes and
window boundaries preserve event order. The regression sends 128 moves between UI
updates through a real `UIWindow` and the production sidebars. In Windows Debug,
unbatched hierarchy input caused 1275 rebuilds in 560 ms; batched input stayed at
10 rebuilds and at most 11 ms. The 600-file tree went from 765 rebuilds in 546 ms
to at most 6 rebuilds and 9 ms. These timings cover input/update/layout, excluding
tessellation, rendering and display. Neighboring row caches retain their revisions.
Ten focused tests passed, including input ordering and raw-event preservation;
logs: `.build-tools/hover-burst-tests.log`. This does not establish a display FPS.

The optimized editor was rebuilt and opened on Skeletal Garden's 539-entity scene.
A subsequent 30-second PresentMon capture, with no compiler running, measured
53.84 displayed FPS, 18.58 ms mean display interval and 24.20 ms display p99.
Present p99 was 21.89 ms. The capture did not establish continuous rapid pointer
motion; use the burst regression for the bounded input-work comparison above.
Capture and environment metadata: `.build-tools/performance/hover-release-editor.*`.
The locally staged Release executable is `.build-tools/hover-release-studio/AdaEditor.exe`.
Later spot checks showed 27–28 ms on the overlay while background CPU activity
was present. The bounded capture is not a guarantee of sustained 60 FPS.

Scene selection previously passed complete terrain payloads through Yams' Codable
sequence encoder. A Windows debugger capture during a Skeletal Garden viewport click
located the stall in `EditorSceneViewportModel.selectEntity` → `encodedYAML` →
`Node.Sequence.replaceSubrange`, while encoding a 4225-element payload array.
`EditorSceneValue` now constructs collection nodes in bulk. Viewport document updates
reuse the parsed model instead of decoding the same YAML twice, and selection/foldout
changes preserve the preview's runtime entities. The scene selection regression suite
exercises a real viewport click with 8192 terrain vertices, selection persistence,
scalar round trips, and runtime retention across editor state changes.

`Time.absolute` uses QueryPerformanceCounter and caches its immutable frequency.
The previous Foundation uptime clock advanced in approximately 15 ms steps on
the tested Windows Swift toolchain. That is too coarse for a 16.67 ms frame.
Microsoft documents QPC's monotonic interval clock and fixed frequency in
[Acquiring high-resolution time stamps](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps).

Studio requests display synchronization on Windows. The existing WebGPU FIFO
swapchain provides the visible window's pacing; the Windows application loop
does not add another `Task.sleep` after a display-paced frame. Fixed-rate,
headless and fully hidden/minimized configurations retain the timed fallback.
This also lets Studio follow monitors with refresh rates above 60 Hz.

## Validation machine

2026-10-15: Windows 11 Pro 10.0.26200, Swift 6.3.1, Ryzen 9 7900X,
32 GB RAM, NVIDIA RTX 4070, D3D12/WebGPU. Native `EnumDisplayDevicesW` /
`EnumDisplaySettingsW(ENUM_CURRENT_SETTINGS)` report the attached primary display
as 2560×1080 at 144 Hz. CIM's video-controller inventory instead reported stale
60/143 Hz adapter modes; do not use that inventory as the active monitor rate.
Editor captures use the primary display, a maximized 2560×1032 client and the
existing My_Gam scene with one root entity.

The baseline at commit `9188df5c`, before timing changes, recorded 32.58 present
FPS and 32.58 displayed FPS over 29.56 seconds (963 measured intervals).
Present p95/p99 were 32.27/390.50 ms, with a worst interval of 426.41 ms.
GPU busy time averaged 4.18 ms, with p95 7.48 ms. Replacing the clock alone
left the extra sleep in place: 28.53 present/display FPS, p95 32.42 ms.
With the display-pacing change, 30-second captures recorded:

| Workload | Present FPS | Display FPS | Present p95 / p99 | Worst present interval |
| --- | ---: | ---: | ---: | ---: |
| 2D editor, idle | 143.99 | 144.00 | 7.37 / 7.81 ms | 12.63 ms |
| 3D editor, idle | 143.95 | 143.94 | 7.39 / 8.41 ms | 14.79 ms |

Both idle captures had zero intervals above the 16.67 ms budget for 60 FPS.
Input testing then exposed another issue: native wheel zoom reached 123.75 FPS
on average but had p99 96.66 ms / worst 111.28 ms. A separate 500 ms CPU capture
located a 231 ms update in `AdaUI.UpdateWindowManagerSystem`; it is diagnostic
evidence, not an FPS measurement. Caption hit-region collection previously walked
the whole UI twice on each layout, including content outside the caption. It now
uses one pass, filters controls by caption geometry before protocol checks, and
prunes clipping ancestors outside the caption while preserving overflowing controls
in non-clipping containers. Camera movement also updates a localized observable
presentation model for the rulers/status rather than rebuilding the viewport host.

The larger Skeletal Garden scene (539 entities) exposed a second caption issue.
The command closure in the caption environment was recreated on every layout.
Environment comparison treated each closure-bearing value as changed, invalidating
geometry content and reconciling the complete hierarchy again. With a game window
open, a bounded CPU capture recorded 2282.01 ms in `AdaUI.UpdateWindowManagerSystem`;
PresentMon measured 0.427 present/display FPS per window (five intervals spanning
11.71 seconds, worst 2352.39 ms). This is a UI stall, not the reciprocal of GPU time.
Caption presentation now has a stable, weakly window-bound command target and
value equality for its visible state. The hierarchy uses lazy rows with a 34-point
height estimate, keeping distant entities accessible through scrolling.

The editor navigation camera now inherits the active authored camera's background,
IBL and quality settings. Previously it used a separate default environment and
forced reflections on in 3D, so the preview did not match Run. Authored lighting
values are preserved; comparison screenshots must use the same pose and settings.

After the stable caption fix, the same 539-entity garden recorded 34.79 present
FPS in the maximized editor (p95/p99 30.80/32.49 ms, worst 42.70 ms). Running
the game alongside its editor preview recorded 13.30 FPS per native window
(p95/p99 90.74/94.68 ms, worst 147.14 ms). These intermediate captures are
`garden-final-idle.csv` and `garden-final-game.csv`; their names predate the
subsequent annotation caching and inactive-preview changes and do not describe
the final implementation. They establish that removing the multi-second UI stall
alone did not achieve 60 FPS on this scene.

The next changes retain the grid and gizmo drawing groups until navigation or
scene edits invalidate them. The live scene texture remains independent. Editor
`SceneView` opts out of updates while its window is inactive; its coordinator
suspends the complete preview runtime (including its render subworld) in the
host's automatic frame loop and resumes the same runtime on activation. It stays
registered for ACP/MCP discovery, inspection and explicit updates. The game keeps
the default background-update behavior. Native Debug validation confirmed a
right-button camera rotation updates both the scene and annotations, and that
the scene and annotations resume correctly after switching between the editor and the
native game window. The initial detach-based implementation was replaced to
preserve tooling access while the editor is inactive.

Focused validation passed 33 editor tests covering retained annotations, local
presentation invalidation, preview suspension/resumption, authored environment,
lazy hierarchy/file-tree selection, stable play inspection and gizmo interaction.
A fully started Run activity keeps its progress indicator static; unfinished
operations still animate. This avoids continuously redrawing the editor while
the game is running. Another 58 AdaUI tests cover
caption stability/regions, environment propagation, lazy stacks and offscreen
input/lifecycle behavior, including both inactive-update policies. These runs do
not establish display FPS. Broader headless rendering suites still encounter
the existing combined-sampler GLSL compilation failure; native D3D12 rendering
was exercised separately.

Stopping the background scene by itself recorded 21.49 FPS in the game and the
editor's separate native swapchain, with game p95/p99 63.58/65.79 ms. A bounded
CPU capture still measured repeated editor UI drawing/tessellation and natural
sorting of the live entity list. The project navigator now mounts only visible
rows, and the play entity picker preserves its sorted inventory between unchanged
refreshes while continuing to refresh selected component values.

The WebGPU pipeline's bind-group cache previously cleared every entry after
512 distinct bindings. A large scene multiplies material bindings across buffered
uniforms and shadow cascades, so that limit can repeatedly discard the active
working set. Its limit is now 8192, with a bounded FIFO ring that evicts one entry
on overflow rather than discarding unrelated bindings. Cached owners remain
retained to prevent resource identity reuse; eviction releases them. The cache
tests include capacity overflow, failed creation, ring wraparound, independent
copies and a 539 × 3 × 3 binding working set.

The main 3D pass also uses a per-camera ring of view-uniform buffers. Inline
camera bytes allocated a fresh WebGPU buffer on every pass, changing the resource
identity in every material's bind-group key each frame. Reusing the buffered
uniforms preserves those keys while uploading the current matrices, including
temporal jitter. Tests read back the uploaded matrices, verify the in-flight
buffer count and check that different cameras and removed views keep independent
buffer lifetimes. The six binding-cache tests passed, and the native Windows
`script/validate_webgpu.sh` run passed seven tests, including fresh Tint
conversion and GPU-pixel checks, with the pinned Dawn backend and Swift 6.3.1.

The same buffering is used for UI projections, independently per source camera.
Previously every UI pass allocated a new inline uniform buffer, invalidating the
binding key of retained UI draws even when their geometry and textures were
unchanged. The UI regression test uploads changing projections, reads them back,
and checks reuse, camera isolation and pruning. Directional-shadow traces now
separate list preparation (`Render3D.ShadowPrepare`) from command encoding
(`Render3D.ShadowEncode`) for further CPU diagnosis.

Before the UI-projection change, `garden-buffered-game-clean.csv` recorded
31.42 present/display FPS in each native window over 30 seconds (game present
p95/p99 40.83/46.62 ms, worst 81.00 ms). Continuous tracing was explicitly
disabled; no compiler ran during that capture. Game GPU busy time averaged
5.54 ms. A separate 15-second diagnostic capture after minimizing/restoring
the editor geometry recorded 35.48 FPS; it is not a comparison at the same
editor size. These are intermediate results and do not satisfy the 60 FPS goal.

Keep detailed CPU captures short: their JSONL recording/decoding changes timing.
Five-second detailed captures produced large in-memory results on this machine;
they are excluded from the display-FPS results above.

These captures establish performance for the measured Studio workloads on this
machine. They do not establish a minimum FPS for arbitrary user scenes or hardware.

## Window demand and stability validation (2026-10-15)

UI window cameras now opt into presentation on demand. A completed scene texture
requests presentation separately from UI geometry invalidation; an unchanged
inactive editor does not need another swapchain image. Ordinary scene cameras
and windows owned by an embedded runtime retain continuous presentation. Windows
frame pacing checks the actual visible windows so an active game does not inherit
the inactive editor's idle sleep.

A pending redraw survives unsuccessful drawable acquisition, including the
temporary skips during WebGPU surface resizing. The request is acknowledged when
acquisition succeeds, and requests for closed windows are discarded. Native
startup validation also caught an ECS resource-query defect: `Res<T?>` constructed
through `Extract` used a different lookup from subsequent updates and trapped
even when the wrapped resource existed. Construction now uses `getFromWorld`,
matching update semantics, with absent/present/replaced/removed resource tests.

PBR material parameters share immutable buffers by value; material changes select
a new buffer without overwriting data referenced by earlier draws. The WebGPU
encoder skips unchanged resource bindings while rebinding retained resources on
pipeline changes. Tests exercise changed offsets, textures, samplers and pipeline
layouts using actual D3D12 pixels, as well as in-flight material-buffer contents.

`script/validate_webgpu.sh` passed 26 tests in nine suites on the RTX 4070 with
Swift 6.3.1 and the pinned Dawn/Tint toolchain. A separate focused AdaUI run passed
65 tests covering offscreen viewports, captions, environment propagation and lazy
stacks. The broader UI suite remains unverified: existing navigation/animation
test compilation errors and the headless combined-sampler text-shader failure
prevent a clean full-suite run. These limitations are separate from the focused
GPU and UI results.

The first native build of these changes measured 51.89 displayed FPS in the
maximized 2560 × 1032 editor and 61.60 displayed FPS in the 1100 × 800 game
window, with the editor inactive. Each PresentMon capture lasted 30 seconds;
tracing was disabled and no compiler ran. Present p99 was 22.02 ms and 18.99 ms,
respectively (`stability-editor-after.csv`, `stability-game-after.csv`). Restoring
the game after minimizing/maximizing retained rendering and keyboard input;
returning to the editor measured 51.28 displayed FPS.

These are intermediate results: the editor's private committed memory continued
growing toward 8.2 GB despite a working set below 1 GB. Inline uniform bytes create
a unique GPU buffer per call; retaining their bind groups in the long-lived
pipeline cache cannot provide cross-frame hits and holds the associated native
allocations. Bind groups containing an inline uniform now bypass that cache.
Buffered uniforms retain normal caching. The GPU regression test repeatedly draws
inline constants, verifies the pipeline cache does not grow, and checks the
resulting pixels together with the reusable-buffer path.

Final native validation, with the inline-buffer cache fix and the same scene,
window sizes, tracing state and 30-second capture duration:

| Workload | Display FPS | Present p99 | Display p99 | Working set at capture end |
| --- | ---: | ---: | ---: | ---: |
| Maximized editor | 52.37 | 21.37 ms | 24.15 ms | 401 MB |
| Game, editor inactive | 62.83 | 18.74 ms | 24.01 ms | 461 MB |

The editor's 120-second memory sample stayed between 1.1399 and 1.1438 GB of
private committed memory, without the previous linear growth. During the game
capture private bytes stayed near 1.609 GB. Working set and private committed
memory measure different things; the table is not a claim of total GPU memory
usage or a long-duration leak test. The captures are `stability-final-editor.csv`
and `stability-final-game.csv`, with process/compiler metadata alongside them and
five-second memory samples in `stability-final-editor.memory.csv`. No compiler
ran during these final FPS captures. These results still do not establish a
minimum of 60 FPS for the editor.

Subsequent animation validation found that the game captures above used a frozen
robot pose: scene navigation copied entities into the runtime world without
remapping model-root references. They are not a baseline for the fully animated
game workload. See the animation validation below for the corrected build.

The final Release executable was packaged as
`dist/AdaStudio-stability-2026-10-15-windows-x86_64.zip`; relocation smoke checks
passed. Its executable matches the final build after the packaging script's
normal PE subsystem conversion. The original `Editor/Package.resolved` contents
were preserved after validation.

## Scene animation transfer validation (2026-10-15)

`SceneNavigator` now remaps model-node, skin and model-source root references
after copying the complete scene hierarchy. Copied skins retain their current
pose and receive a separate GPU palette identity. Scene replacement also declares
exclusive world access so it cannot invalidate component pointers being traversed
by another system.

The regression test with the actual GardenRobot model passed when instantiated
directly but failed after navigation before the fix: the playback clock and pose
advanced while `UpperLeg.L` remained at its rest transform. The corrected path
passes. All 15 AdaScene tests in five suites passed in the focused validation
package, including autoplay, controlled playback, joint transforms, skin palettes,
pause, reload, preservation of a paused pose, source-scene independence and
existing scene lifecycle tests.

The Release package was exercised through the native Run window on Windows/D3D12.
Both robots changed joint transforms over time; keyboard-driven walking, running
and jumping visibly changed the controlled robot's pose. A clean 30-second
PresentMon capture with the editor inactive measured 60.33 displayed FPS,
19.05 ms present p99 and 23.72 ms display p99 (`animation-game-first.csv`). No
compiler or detailed CPU recording ran during this capture.

That measurement followed closing an orphaned blank launcher window. Opening a
project while Studio was unfocused left `activeWindow` empty, so the launcher's
close call had no target. Keeping that extra window open measured roughly
17–18 FPS in the overlay; closing it restored roughly 60 FPS. Project opening now
falls back to the previous primary window when there is no active window.

An extended native run also produced a Swift trap in the AdaScript bridge. The
Windows minidump identified a failed conversion of the query iterator receiver
to `AnnotatedGravityQueryBridge`. Callback setup held newly allocated `GSValue`s
only in Swift while `setStoredProperty` allocated its lookup key; these temporary
values are invisible to the VM collector. Setup now suspends collection while
binding queries, resources and events, and resumes it before user code runs.
This closes that unrooted allocation interval without disabling normal collection.

The focused validation package passed 29 tests in nine suites, including 50,000
script updates with varying temporary allocations, two queries and an Input
resource. The test checks all 100,000 component increments, valid input access
and restored collection state. The initial simpler stress workload did not
reproduce the native trap; the minidump and allocation lifetime analysis motivated
this guard. This is bounded validation, not proof that every long-running script
is crash-free. Logs are `animation-gc-after.log`, `animation-crash-registers.log`
and `animation-crash-symbols.log` under `.build-tools/performance`.

The final packaged build automatically closed the unfocused launcher and was
exercised again in the native game window, including jumping. Its clean
30-second capture measured 59.63 displayed FPS, 19.47 ms present p99 and
23.97 ms display p99 (`animation-stability-game.csv`). Private committed memory
was 1.602–1.603 GB during the capture; no compiler or tracing session was active.
The game window was 1100 × 800, with the maximized editor inactive.
The subsequent 120-second memory sample stayed within 1.604–1.608 GB of private
committed memory (24 samples, five-second intervals). The final process remained
alive and the native game remained running after these checks.

Release build and relocation/tool smoke checks passed for
`dist/AdaStudio-animation-stability-2026-10-15-windows-x86_64.zip` (SHA-256
`c71078019d124e4eeaae03f0f9a1027bd989eee5a01703241e76e9b668fe8e4a`).
The original `Editor/Package.resolved` contents were restored after validation.

## Authored lighting parity (2026-10-15)

The Skeletal Garden scene had SSR explicitly disabled and `Studio.ibl` assigned
at intensity 0.5. Before the viewport parity change, the editor instead used its
default procedural sky, no IBL asset, and enabled SSR. Copying the authored camera
environment into the editor exposed the game's brighter appearance in both views.
The current composite shader also skips its SSR path when baked IBL is present;
enabling the scene's SSR checkbox alone would not restore that previous preview.

Restored the previous preview environment in the project's
`Assets/Scenes/Main.ascn`: explicit default procedural sky, enabled SSR, and no
`Studio.ibl` override. The IBL asset remains available in the project. Existing
SSAO, FXAA, directional/local shadows and visibility settings are retained. This
is a scene correction, with no new renderer binary or shader modification.
The edit went through scene history and Save; comparison of parsed YAML confirmed
that only camera `garden-0538`'s `Environment3D` changed among all 539 entities.
The original scene is backed up as `.build-tools/performance/Main.before-lighting.ascn`.

Native Run was restarted from the saved scene. Both its output and the maximized
editor visibly restored the darker landscape, colored local lighting and glossy
reflections. Separate 30-second PresentMon captures measured 59.84 displayed FPS
in the 1100 x 800 game window (editor inactive) and 51.74 FPS in the maximized
editor (game stopped). Present p99 was 19.22 ms / 22.21 ms and display p99 was
23.92 ms / 24.35 ms respectively. Captures and compiler metadata are
`lighting-restored-game.*` and `lighting-restored-editor.*` under
`.build-tools/performance`; neither capture overlapped a build. These measurements
supersede the earlier game captures for assessing the requested lighting quality;
they do not establish 60 FPS for the editor or for simultaneous foreground views.

## Windows background tool windows (2026-10-15)

Tint inherited the default Windows console policy. When launched by the GUI
release executable without a parent console, each shader compilation could
create a transient console window. The renderer now passes `CREATE_NO_WINDOW`
and a hidden startup window to Swift Subprocess. Shader output and errors still
travel through captured pipes.

Studio's existing native ACP process launcher is now shared by its build/tool
runner, Swift toolchain lookup and SourceKit-LSP. It uses `CREATE_NO_WINDOW`,
UTF-16 arguments/environment and explicitly inherited stdio handles. ACP and LSP
keep job-based process-tree ownership; ordinary commands retain their previous
direct-process cancellation semantics so services such as adb can persist.
The tool runner drains stdout/stderr concurrently, retains split UTF-8 output,
and waits for termination after cancellation.

An isolated Swift Testing package compiled the actual five Windows tool source
files and passed five subprocess tests: `GetConsoleWindow() == 0`, argument/cwd/
environment preservation, large stderr and split UTF-8 output, cancellation,
missing-tool errors, and bidirectional supervised stdio. The suite is checked in
as `EditorWindowsBackgroundProcessTests`; its execution log is
`.build-tools/performance/no-console-tools-tests.log`. This was focused validation,
not the full editor test suite.

`script/validate_webgpu.sh` also passed all 26 tests in nine suites, including
fresh Tint SPIR-V conversion and real D3D12 GPU pixel checks on RTX 4070 with the
installed Swift 6.3.1 toolchain. Its log is
`.build-tools/performance/no-console-webgpu-validation.log`.
