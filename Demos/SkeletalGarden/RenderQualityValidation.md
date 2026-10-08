# Render quality validation

Native macOS/Metal check, 2026-10-04. Apple M3 Pro, 2200x1520 render target. Same garden, camera and frozen poses for both robots. Measurements use Metal command-buffer GPU timestamps, serialize passes in profiling mode only, discard 20 warmup samples per pass, and include 140 subsequent samples. Normal play remains asynchronous.

## GPU measurements

| Pass | Minimum ms | Mean ms |
| --- | ---: | ---: |
| shadows | 0.284 | 1.032 |
| geometry | 1.202 | 4.704 |
| ssao | 1.466 | 5.637 |
| composite | 0.625 | 2.012 |
| fxaa | 0.111 | 0.887 |

One shadow map with SSAO/FXAA retained: 0.113ms minimum, 0.524ms mean. Three cascades: 0.284ms minimum, 1.032ms mean.

These are local pass-duration measurements, not guaranteed budgets or a production FPS estimate. GPU clock/load varied during the run; the averages include outliers. Profiling serialization changes scheduling, so do not interpret the sum as asynchronous frame time.

## Image controls

- `dist/captures/quality`: three cascades + SSAO + FXAA.
- `dist/captures/baseline`: legacy one-map coverage, SSAO/FXAA off.
- `dist/captures/no-ao`: SSAO off, cascades/FXAA unchanged.
- `dist/captures/no-aa`: FXAA off, cascades/SSAO unchanged.
- `dist/captures/single-shadows`: one map, SSAO/FXAA unchanged.
- `dist/captures/no-shadows`: sunlight shadows off, SSAO/FXAA unchanged.

GPU readback captures were visually inspected. Pixel comparisons at the same 2200x1520 resolution show SSAO darkening contacts and FXAA changing silhouette/edge pixels. The opaque indirect buffer is separate from direct lighting/emission; transparent foreground preserves opaque geometry buffers and attenuates their indirect contribution.

The scripted dynamic scene passed crate collision, braking, camera obstruction, Jump/Fall/Land and terrain traversal with the quality pipeline enabled. Generic frustum-fit tests cover all eight corners per cascade and sub-texel camera motion. Additional tests cover old Environment3D decoding, odd-sized half-resolution targets, reuse of GPU allocations, per-camera uniform isolation and transparent blend state.

This run validates Metal. Shader sources pass the engine compiler; WebGPU/OpenGL execution was not tested. The FXAA pass is spatial and has no temporal history.

## Regression result

Final full SwiftPM run: 1230 tests in 213 suites passed. Targeted SwiftLint and git diff --check passed. A wall-clock-dependent lifecycle test was stabilized with an explicit 1/60s scheduler step; no lifecycle runtime behavior was changed. The final normal asynchronous Metal scene also passed the scripted controller/camera/jump/terrain checks after lazy effect-pipeline creation was introduced.
