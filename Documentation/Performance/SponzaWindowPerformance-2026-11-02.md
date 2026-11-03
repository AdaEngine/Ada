# Sponza interactive performance and camera investigation — 2026-11-02

## Scope

Investigate the reported outside-view slowdown (~25 FPS with low GPU load), swapped camera axes/roll,
and the gallery slowdown (~65 FPS at 94% GPU load in the supplied full-size screenshot).
The demo uses the prepared Intel Sponza + Ivy PBR assets, 8,812,576 source triangles, +3 EV,
three directional shadow cascades and Hi-Z disabled. Meshlets are not implemented by this change.

## Camera

The demo previously passed pitch/yaw through the engine's legacy Euler convention. It now composes
world-Y yaw and local-X pitch explicitly, clamps pitch and preserves the selected route pose.
WASD is camera-relative, Q/E changes world height, diagonal speed is normalized, and right mouse uses
the engine mouse-capture component. Escape cancels capture until the button is released.
Three production-helper tests pass: axis directions/no roll, resetting/first mouse delta, and movement.

## Frame completion

Native WebGPU queue completion previously depended on ProcessEvents plus a one-millisecond Swift sleep.
The window could become limited by callback delivery rather than GPU rendering. Native completion now
allows spontaneous callbacks. A weak, delayed native dispatch fallback checks pending operations every
100 ms for idle/headless copy submissions; completed commands are not retained by that fallback.
User handlers are still delivered outside the device lock and gated to run once.
The browser path is unchanged. Device-loss reporting also allows spontaneous native delivery.

The historical control in `window-profile-before.json.gz` measured outside at 20.6 / 23.7 / 24.1 FPS
at 3810 × 1883 with shadows. Removing all event pumping experimentally reached 102.2 / 101.4 / 95.8 FPS,
but stalled a headless copy-only fence, so that experiment is not the shipped implementation.
Frequent polling, WaitAny-only delivery and spontaneous delivery with an immediate native wait were
also rejected. Their raw measurements are retained, including slow results and mixed-size runs.
`ADAENGINE_WEBGPU_LEGACY_COMPLETION=1` provides the old polling control in the same binary.

## Measurement

The opt-in window profiler records SceneView publication intervals, without image readback in measured
intervals. It visits atrium, gallery and outside with three alternating shadow-on/off pairs: one second
warmup, then two seconds measurement per case. Throughput is interval count / summed interval duration;
median intervals are reported separately. Graph diagnostics are CPU encoding times, not GPU timestamps.

Machine: Windows, RTX 4070, D3D12 driver 32.0.16.1088, Swift 6.3.1. Desktop/UI/RTSS remain active.
Small-window scene resolution is 1890 × 1030; maximized is 3810 × 1883. Their aspect ratios differ slightly.
A full-size run must start maximized: resizing mid-run invalidates the affected comparison.
The early `idle-large` run was resized during the outside cases and is retained as a mixed-size diagnostic.
The `idle-small` and `idle-maximized` runs used a strongly retained fallback and are diagnostic experiments.

## Final full-size result

Final weak-fallback implementation, scene 3810 × 1883 throughout, three cases per setting:

| View | Shadows on: median throughput (range) | Shadows off: median throughput (range) |
| --- | --- | --- |
| Atrium | 67.3 FPS (66.2–77.2) | 137.5 FPS (133.5–138.7) |
| Gallery | 53.1 FPS (41.0–54.0) | 54.2 FPS (45.6–62.7) |
| Outside | 95.1 FPS (94.6–95.5) | 110.2 FPS (109.2–111.1) |

Outside no longer exhibits the old ~25 FPS pacing limit. The gallery issue remains: its median intervals
are 12.4–12.9 ms with shadows, but p95 intervals reach 35–36 ms and one case contains a 266 ms frame.
Average throughput therefore differs substantially from inverse-median-frame-time or a momentary overlay.
The fixed gallery pose is a reproducible starting point, not an exact reconstruction of the user's free camera.

Earlier small-window diagnostic gallery cases reached 85–92 FPS with shadows and 123–131 FPS without.
That implementation retained fallback work more strongly, so it is not a strict final-code resolution A/B.
The supplied screenshot's 94% GPU load and these controls suggest substantial GPU work; they do not prove
that geometry, fragments, shadows or residency alone are the bottleneck. The full-size shadow-off control
still has long frames. Do not promise that meshlets alone will remove this slowdown.

A closed-demo GPU snapshot during the investigation still showed 39% utilization and 3753 MiB used.
The desktop was not quiet; absolute throughput and long frames may include competing GPU work.
Priorities for the next performance pass: GPU timestamps per pass; DXGI memory budget/residency and shared
memory telemetry; then a quiet-machine resolution control and visibility/culling A/B at the gallery pose.
Preserve this gallery case alongside atrium, corridor and outside when validating meshlet culling.

## Validation and known unrelated failures

Final implementation: release demo build and native test-product build passed. The final focused run passed
three tests (copy-only completion/reentrancy, auto-exposure copy progress, and fresh path shader compilation).
The camera helper passed its three tests separately.

The native focused completion test copies real GPU buffer data, awaits the fence without an app pump,
then submits another command from its handler. It checks exactly-once delivery, reentrancy and copied bytes.
The auto-exposure test that awaits a copy-only fence also passes after restoring idle progress.

The broad validation filter from `script/validate_webgpu.sh` ran 295 tests in 68 suites in 258 seconds;
it reported 25 issues. Re-running its 16 failing tests with legacy completion reproduced 24 issues:
all 22 actual golden PNGs were byte-for-byte identical, and the IOR-brightness and sampling-only sprite
assertions also failed with legacy completion. No golden references were replaced.
The remaining issue was a source-relative path-tracing shader absent from the staged validation package.
The staging script now copies that shader directory; the fresh shader compilation then passed in the control run.
This is not a clean full-suite pass. The complete logs and PNG hashes are retained beside the profiles.
Tint tool hash/reader-writer smoke and fresh SPIR-V → WGSL conversion tests passed.

Evidence: [SponzaWindow-2026-11-02](../../Evidence/Meshlets/SponzaWindow-2026-11-02).
Raw profiles are gzip-compressed JSON; earlier meshlet preparation and benchmark evidence is unchanged.
