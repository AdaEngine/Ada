# Local lighting validation

Native macOS/Metal, Apple M3 Pro, 2026-10-05. Fixed 2200x1520 final output;
geometry, camera, lighting environment and robot poses stay fixed for controls.

## Runtime controls

| Capture | Selected local lights | Shadowed lights | Faces |
| --- | ---: | ---: | ---: |
| local-lights | 2 point + 1 spot | 3 | 13 |
| local-no-lights | 0 | 0 | 0 |
| local-unshadowed | 2 point + 1 spot | 0 | 0 |
| local-point | 1 point | 1 | 6 |
| local-spot | 1 spot | 1 | 1 |
| local-budget | 2 point + 1 spot | 1 prioritized spot | 1 |
| local-many | 31 point + 1 spot out of 43 local sources | 4 | 19 |
| local-moving | 2 point + 1 spot | 3 | 13 |

All controls retain two directional sources: a dim primary shadowed sun and a
cool unshadowed fill. Thus `local-no-lights` isolates local illumination rather
than removing all scene lighting. Atlas sizes are 3072x2048 with the default
four-light budget, and 3072x512 with a one-light budget. Disabled/no-light scenes
allocate no local atlas. The moving control animates the camera, a point source
and the main character pose; static point/spot captures and moving images were
visually inspected. GPU counters are written separately from GPU timings.

The multi-camera control rendered the window and a 480x320 texture camera, each
with independent atlases, local light lists, shadow matrices and inverse-view
buffers. Both selected three local lights and rendered 13 shadow faces. The
texture camera also changed temporal input resolution and paused/resumed.
The final shader/uniform implementation reproduced the original fixed control
frame bit-for-bit (zero changed pixels).

## Pixel and performance evidence

At frame 50, enabling local lights changed 1,733,455 pixels by more than two
8-bit channel levels; mean absolute channel difference was 11.784. Enabling
local shadows against the same lit unshadowed control changed 369,668 pixels;
mean absolute channel difference was 2.276. These comparisons establish actual
GPU lighting/shadow contribution, not physically accurate light calibration.

A final three-light native run measured local-shadow GPU durations of 0.326 ms
minimum / 3.028 ms mean, and geometry 1.865 / 15.351 ms after 20 warmup and 140
measured samples. The 32-light control measured geometry 5.915 / 25.814 ms and
local shadows 0.369 / 2.423 ms. Other builds/apps and GPU clock/load varied.
Profiling serializes passes; neither summed pass durations nor these averages
are a production FPS estimate. Normal gameplay remains asynchronous.

## Verification and limits

Normal asynchronous gameplay also passed `--verify-local-lights` with local
shadows and MetalFX Temporal together: crate stop, movement/braking, camera
obstruction, Jump/Fall/Land and terrain traversal.

Full engine regression: 1250 tests in 218 suites passed. Seven focused local
lighting tests cover attenuation/cones, cube/spot projection, per-camera caps,
slot stability/priority/removal, scene payload compatibility, transform/hidden
hierarchy extraction, per-camera GPU buffers and offscreen shadow casters with
atlas reuse. Six Editor catalogue tests passed, including edited local light
settings saved and loaded through the production scene loader and camera shadow
budget controls. Task-owned source/test files passed strict SwiftLint and
`git diff --check` passed. Package.swift retains ten pre-existing lint violations;
the resource-exclusion change adds none.

The forward implementation is intentionally bounded: four directional lights
with shadows for the primary sun, 32 local lights and up to four local shadow
lights per camera. Shadow tiles use RGBA16F normalized-depth color plus a depth
attachment, nearest sampling and nine clamped PCF taps. Bias is configurable;
point cube-face seams, transparency shadows, adaptive resolution and clustered
assignment need separate quality/performance work. Apple mobile and WebGPU
execution and visual Inspector interaction were not validated by this run.
