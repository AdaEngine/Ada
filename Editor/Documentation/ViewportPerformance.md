# Viewport synchronization and performance

These measurements and executable test runs were collected in the Windows Studio
integration workspace. The viewport changes are extracted onto `main` independently
of its Windows platform, packaging, selection and sidebar work. They establish the
integration behavior, not a fresh build or benchmark of the extracted PR branch.

## Camera navigation and annotation presentation

For the Windows Vulkan camera-orbit comparison with an open inspector, see the
[frame-time and input-latency measurements](WindowsPerformance.md).

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

## 3D scenes in the 2D viewport

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

## Compass and pointer consistency

The compass observes a separate orientation value published with the completed
scene frame. Rotating the camera updates its Canvas and axis labels while leaving
the viewport host, hidden rulers and unchanged status label alone.

Transform-handle geometry is retained alongside the presented annotation commands.
Hover and drag start use that geometry, including its camera projection, rather
than the newer navigation state. During a target resize, pointer coordinates map
back into the captured target, matching the stretched texture and annotations.
An explicitly empty handle snapshot stays empty until a matching frame is shown;
changing selection, display mode or tool cannot activate an obsolete handle.

Focused regressions exercise the real AdaUI compass drawing and production mouse
and transform-drag paths in `EditorViewportCompassPresentationTests` and
`EditorViewportInteractionPresentationTests`. They cover delayed publication and
both ordinary and doubled viewport sizes. These correctness checks do not add a
new performance measurement to the historical captures above.

The branch now builds independently on Windows with Swift 6.3.1. The focused
editor run passes 45 tests in nine suites, including the new compass/input cases
and the tile source/orientation/occlusion suites. JavaScriptKit is pinned to the
engine's 0.53.0 version because 0.59.0's PackageToJS plugin fails to import
`stderr` on Windows. Windows validation uses the existing local AdaMCP v0.2.0 and prepared
Gravity package via the documented package-path overrides. Logs are under
`.build-tools/pr145/editor-tests-verified.log`. No new native GPU performance
capture was made for this revision.

The engine run passes all 13 selected tests in `SceneViewTests`,
`CanvasRevisionTests`, `AdaScriptSceneSchemaTests` and `PortablePNGTests`
(`.build-tools/pr145/engine-tests.log`). The offline documentation check verifies
21 guides. Obsolete CoreFoundation imports and tile-test AdaMCP PNG fallback
imports were removed to restore Windows compilation after merging main.
