# Real-time path tracing performance in PICA PICA

This draft for approval follows [Solari-inspired path tracing light transport](path-tracing-light-transport.md).

## Problem

PICA PICA should sustain 100 completed frames per second on the RTX 4070 with the patrol running, Ray Reconstruction enabled, and 1440 × 810 output. Use the calibrated display transform and the pinned PICA PICA scene and camera. Compare visible lighting and motion to the Bevy sample at the same output size.

The AdaEngine Release probe measured 26.74 ms per completed frame with full-resolution tracing and two samples per pixel. With one sample and a 965 × 543 tracing input it measured 17.08 ms with the cache and 16.56 ms without it. A moving robot invalidated nearly every cache frame. Bevy measured 16.65 ms with its default present mode and 8.68 ms with no VSync at 1440 × 810 tracing and output. AdaEngine's attempt to request a latest-frame presentation mode reported FIFO on this surface. The AdaEngine measurements include presentation and do not identify the time spent in the tracer alone.

## Behavior and ownership

- Add a diagnostic mode that compares GPU pass time, completed rendered frames, and presented frames using a stable physical output size. Keep the desktop defaults and record the effective presentation mode. If the target needs uncapped presentation, implement the existing `RenderPresentationMode.uncapped` intent through AdaRender and SAGA Vulkan. Use an advertised non-VSync mode when available and report the actual fallback. Apply it explicitly in the performance demo. Other platforms retain their current behavior.
- Profile the existing Vulkan ray-query, scene upload, world-cache, and Ray Reconstruction paths separately. On transform-only updates, preserve immutable geometry and material uploads where their contents are unchanged. Preserve acceleration data, emitter positions, and visibility for moving objects. Use the measured bottleneck to decide whether further work is needed on light sampling or pass overhead.
- Make light changes responsive without restarting every temporal resource. Preserve valid diffuse cache cells on compatible changes and update or retire affected cells. Local moving emitters and doors must respond without leaving persistent light leaks or old shadows. Camera cuts, geometry replacement, and cache-incompatible edits still start fresh as needed. Keep the portable and uncached paths available for comparison.

Lowering the physical output resolution would change the test. Lowering the tracing input is acceptable within the visual comparison. Leaving the cache disabled did little for frame time in the observed moving-scene run and would remove a lighting input the test is meant to cover. FIFO presentation stays available for normal use.

## Acceptance and documentation

Run Bevy and AdaEngine sequentially on the same RTX 4070 at 1440 × 810 after warm-up. Record mean and tail frame times, trace dimensions, provider, cache mode, and effective presentation mode, with the robot both still and moving. The moving AdaEngine run must complete at least 100 actual rendered frames per second on average, without counting generated or repeated frames. Record matched stills and the sun-off and lamp-off transitions to check the deepest shadows, indirect light near the clock, shadow boundaries and reflections. Include a hardware-path regression test for transform-only resource reuse and an invalidation test if cache behavior changes.

Update the user-facing [hardware path tracing article](../../Sources/AdaEngine/AdaEngine.docc/Articles/3D/HardwarePathTracing.md) and the Solari Comparison README with the supported runtime, switches, and validated benchmark procedure. Check article navigation and build the example with the published instructions.
