# Sponza: load time, frame pacing and main-pass binding cost — 2026-11-09

Windows 11, RTX 4070 12 GiB, Dawn D3D12, Swift 6.3.1 release, 3840×2160 display at 143 Hz (150% scale).
Demo: `AdaExamples/Examples/Technical/Sponza`, full raster preset, GPU meshlets, LOD 2 px, no DLSS in this build.
Measurements use the demo's `ADAENGINE_SPONZA_FRAME_LOG=1` (actual SceneView publication intervals) and
`ADAENGINE_STALL_PROBE=1`. They are single runs on one machine, not a controlled benchmark.

## Load time: 87.6 s → 7.5–9 s (warm file cache)

`ModelAsset3D` decoded and mipped all 75 4096² PNG textures (2 GB) serially. The sRGB mip filter called
`pow` per channel per texel, and `TextureAlphaMask` read 16.7 M texels through `Data` subscripts.

- `ImageMipmaps` uses raw buffers, a 256-entry sRGB decode table and a threshold search that reproduces the
  previous `encodeSRGB` rounding exactly (reference-equivalence tests in `ImageMipmapsTests`).
- Unbounded imports decode and mip textures on background threads, a bounded window ahead of the serial
  material pass that creates GPU textures; errors surface where the serial pass would have thrown them.
  Bounded (`ModelImportContext.limits`) imports keep the serial, budget-first order.
- Without import limits, material creation overlaps sidecar decoding and mesh conversion, and glTF external
  images are read concurrently. The shared-texture key hashes a bounded sample; equality still compares bytes.
- The demo imports Sponza and Ivy concurrently, then the PT LODs (which reuse the uploaded textures).
- The first launch after the OS file cache was evicted took 15.7 s; reading 2.4 GB from disk then dominates.

## Hitches: 170–350 ms stalls removed

With an on-demand UI window that had nothing new to present (the SceneView waiting for GPU completion), the
Windows loop fell back to `Task.sleep` with the 60 FPS fallback limit. `Task.sleep` follows the ~15.6 ms
system tick and occasionally overslept by ~250 ms; while sleeping nothing called into Dawn, so completions
arrived late as well. `WindowsApplication` now waits on a high-resolution waitable timer (woken early by
input) and, for display-synchronized apps, keeps the display's refresh rate as the fallback cadence.

Autopilot (turning and walking) at 1920×1080 points, flying light off, 0 local lights: worst interval went from
~350 ms (several per second in some views) to ~20 ms at view transitions; light views run at the 143 Hz cap.

## Main pass: bind groups were recreated for every draw

Main-pass bind groups include render attachments (shadow atlas, contact depth). Attachments opt out of the
long-lived WebGPU binding cache, so all ~323 main-pass groups were created every frame (~9 µs per draw).
`TransientResourceCache` keeps such groups for up to 16 submissions after their last use, then releases them;
inline-byte uniforms remain uncached. Opaque draws are grouped by material (first-appearance order, stable),
cutting per-frame material switches from ~320 to ~35.

| 1890×784 scene, stationary gallery, flying light off, 0 local lights | Before | After |
| --- | ---: | ---: |
| Main-pass draw encoding | 4.3 ms | 2.0 ms |
| Whole frame (publication interval) | 13.4 ms (74 FPS) | 11.4 ms (87 FPS) |

## Still open

- Full-screen (3810×1684 scene): 69–76 FPS stationary / 111–114 FPS moving with the settings above; the GPU is
  saturated (SM 96–100%) and the CPU frame is ~10 ms. 140 FPS here needs less GPU work per pixel *and* less
  serial CPU work. The scene render world (~7.8 ms) runs after the UI world (~2.6 ms) on one thread;
  overlapping them (pipelined rendering) is a frame-lifecycle change that needs its own design.
- Demo defaults (flying shadowed point light + 12 local lights) remain GPU-heavy (~45 FPS stationary at full
  screen) with occasional spikes while the moving light re-renders its cube faces.
- Dawn `skip_validation` + `disable_robustness` measured about −1 ms CPU per frame; not enabled.
