# MetalFX Temporal validation

Native macOS/Metal, Apple M3 Pro, 2026-10-05. Output: 2200x1520. Temporal and
spatial controls render geometry at 1650x1140 (75 percent of output dimensions).

## Runtime evidence

- `--capture-temporal`: fixed camera and robot poses; frames 30/50 encoded by
  MetalFX with zero fallback frames. Native final-output PNGs were inspected.
- `--capture-temporal-motion`: deterministic camera orbit and character pose
  sequence. GPU velocity readback at frames 30/50 reported 1,881,000 moving
  pixels, zero nonfinite pixels and maximum input displacement about 7 pixels.
  This includes sky motion. Camera, rigid-object and joint motion coordinates
  also have numerical regression tests.
- Static GPU motion readback in multi-camera mode: zero pixels above 0.001 input
  pixels; maximum residual was 0.000197 pixels from floating-point precision.
- `--capture-temporal-multi`: window camera plus a 480x320 texture camera. The
  texture camera starts at 240x160 input, resets explicitly at frame 20, changes
  to 360x240 input at frame 35 and is disabled/re-enabled at frames 60/65. Both
  cameras encode without fallback; at window frames 30/50 only the texture
  camera's reset count changes for these explicit events. Further missing
  drawable/renderer frames legitimately reset their corresponding history.
- `--verify-temporal`: the normal asynchronous renderer passed crate collision,
  movement/braking, camera sphere-sweep obstruction, Jump/Fall/Land and terrain
  traversal. No pass synchronization/profiling mode was enabled for this smoke.
- `--capture-spatial`: final 2200x1520 spatial control, same static geometry,
  materials, camera, lights and poses. Captures now read the final output after
  the presentation upscale rather than the low-resolution main target.

The HDR composite remains linear through reconstruction. ACES tone mapping and
sRGB conversion run afterward. Transparent foreground preserves opaque depth
and motion while marking reactive coverage. UI/scene overlays run after resolve
with the output viewport and unjittered projection; full-resolution depth is
sampled from the jittered geometry target.

## Measurements

One moving temporal capture recorded the combined motion/MetalFX/tone-map/output-depth
group at 4.633 ms minimum and 10.524 ms mean, after 20 warmup samples and
140 measured samples. These are local GPU pass durations; other builds and apps
were active, and clock/load varied. Profiling serializes passes and changes
scheduling. Do not infer asynchronous frame time or an FPS improvement from the
sum of pass durations. The first slice uses an extra mesh-motion pass; merging
motion into geometry MRT output and reducing auxiliary bandwidth are subsequent
optimizations.

Static frame-30/frame-50 comparison: mean absolute 8-bit channel difference
0.104 for temporal and 0.000164 for spatial. Temporal accumulation and different
jitter samples change edge/contact pixels even with frozen poses. This number
is not evidence that temporal filtering universally reduces shimmer. Moving
captures were visually inspected; exhaustive disocclusion/ghosting benchmarks
remain future quality work.

## Verification and limits

The focused history, motion, fallback, output viewport, render-quality and UI
clip run passed 20 tests in five suites. Final full SwiftPM regression passed
1243 tests in 216 suites, with GPU access enabled; the sandboxed full run could
not initialize Metal. Targeted strict SwiftLint and git diff --check passed.
Native UI overlay coverage remains unverified; the output-viewport/fallback
contract is covered by the production render-graph test.

Apple mobile execution and WebGPU execution are not established by this macOS
run. Non-Metal fallback was exercised with the production headless backend;
failed temporal encoding was exercised through the real render graph with a
rejecting scaler. General shader-driven deformation, transparent surface
velocity, dynamic resolution and frame interpolation are outside this slice.
Large lighting/material discontinuities require the author to increment the
camera's `resetGeneration`.
