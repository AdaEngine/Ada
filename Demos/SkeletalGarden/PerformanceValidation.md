# Skeletal Garden performance and GPU visibility

## What changed

The browser bundle is now built in Release. Native `build_and_run.sh` defaults
to Release too; `ADAENGINE_SKELETAL_CONFIGURATION=debug` retains development builds.
Use matching Swift/WASM SDK 6.3.2 for export; native Metal also supports the
repository's standard Swift 6.2.4 toolchain.

WebGPU reuses bounded pipeline bind groups, retaining their resource owners so
identity keys cannot be reused for destroyed resources. Reflection is prepared
once per pipeline; unchanged pipeline state is not rebound. Resource dictionaries
update in place, avoiding per-set copy-on-write allocations. Material uniforms
upload only when values change, independently for every frame-ring slot.
Frustum planes are prepared once per pass. Local lights, shadows, SSAO and FXAA
remain enabled in the ordinary scene.

## GPU visibility contract

Set `Environment3D.meshVisibility.gpuOcclusion = true` or press 0 in the demo.
Metal renders an opaque/alpha-mask depth prepass with the same facing, fade,
material and skinning rules, builds a max-depth Hi-Z chain, tests world bounds,
compacts complete instance records into each draw's reserved segment and writes
indexed indirect counts. Main rendering consumes those counts on the GPU.
Transparent instances remain visible and retain CPU depth sorting. Camera and
shadow lists remain independent.

This implementation consumes current-frame depth. It therefore requires no
previous-frame camera/occluder heuristic or delayed CPU readback. Near-plane
intersections, force-visible entities and unknown/nonfinite bounds are retained.
Odd mip dimensions include their final row/column. Buffers are frame-ringed and
resources are independent per camera. Unsupported devices use CPU visibility;
WebGPU currently uses this fallback. The backend-neutral indirect API reports
unsupported encoders without dropping geometry.

GPU visibility is opt-in: a prepass is extra work in this open, mostly visible
garden. It is not advertised as a speedup for every scene.

## Character LOD and animation

Skinned mesh alternatives explicitly opt into `skeletonCompatible`. Ordered
joints, bind-space coordinates and material slots must match; influence streams
and the animated union of every LOD's envelopes are validated. Invalid/unknown
bounds keep the base mesh. The robot's index-only LODs preserve original GLB
vertices, normalized weights, nodes, inverse binds and clips:
3237 / 2711 / 1491 triangles for LOD0 / LOD1 / LOD2.

`ModelAnimation3DComponent.evaluationLOD` opts into projected-size sampling.
The closest active 3D view controls significance, with hysteresis. Defaults use
every render frame / 30 Hz / 12 Hz, and 8 Hz offscreen. Playback/transition clocks
still advance each frame; smaller visible actors interpolate sampled poses.
Gameplay/root transforms and controller collisions are independent. Playback
replacement, seek, rate changes and non-looping endpoints reset/catch up visual
state. Node/skin references are grouped by model root for one update, replacing
nested whole-world scans. Unchanged palettes reuse both current and previous GPU
uploads; component identities prevent stale data after replacement.

## Reproducible controls

```sh
Demos/SkeletalGarden/script/build_and_run.sh --capture-cpu-visibility
Demos/SkeletalGarden/script/build_and_run.sh --capture-gpu-visibility
Demos/SkeletalGarden/script/build_and_run.sh --capture-crowd-reference
Demos/SkeletalGarden/script/build_and_run.sh --capture-crowd
```

Crowd controls add 64 independently animated actors. `--no-character-lod`
disables character mesh/cadence LOD for the reference. Capture output contains
PNG, visibility/light counters and actual GPU pass timestamps where available.
`gpu-visibility-*.json` reads generated indirect counts after GPU completion.
Native titles include measured frame FPS; `--profile-frames` logs samples.
Browser `?stats=1` counts actual canvas drawable acquisitions per wall-time
interval and shows FPS / ms per frame. It is not a GPU-time measurement.

## Recorded proof and limits

- Original debug WASM: approximately 5.5 FPS in the in-app browser at 1280x720.
- First Release/cache control: approximately 19–20 FPS. Subsequent samples varied
  with simultaneous compiler/Simulator/desktop workload; final measurements are
  recorded separately in `dist/performance`. Comparisons require the same
  viewport, active-tab state, build configuration and background load.
- Metal CPU/GPU visibility capture controls before character LOD introduction:
  frame-50 PNGs match pixel-for-pixel. GPU-generated counts were read back.
- Real Metal compute tests verify complete occlusion, visible instance data,
  camera motion, occluder removal, odd mip edges, force-visible and near-plane
  recovery. This is GPU execution proof, not a source-text test.
- Full native Debug package run: 1263 Swift Testing tests in 228 suites passed.
  Includes cadence/interpolation/playback, rig/weights/material preservation,
  sparse vertex slots, camera/shadow visibility and frame-ring upload reuse.
- Strict SwiftLint passes on the 51 changed runtime/demo/test files. The exporter
  retains its pre-existing lint baseline.
- Swift 6.3.2 native Release hit a compiler crash in existing AdaUI
  `LiquidGlassTabBarControls.body`; the same WASM Release configuration succeeds
  because the Apple SwiftUI bridge is excluded. Native 6.2.4 validation is recorded
  separately. This failure is not a GPU runtime error.

GPU timestamp averages under competing GPU workloads are not universal frame
costs. The first Metal baseline measured approximately 6.9 ms across the recorded
passes; later loaded-host samples were much slower with similar minima. The
reported user run of GPU 36 ms has not been reproduced with the same Xcode
validation/capture configuration. No mobile, Windows or Safari/Chrome proof is
implied by these desktop/in-app-browser checks.


## Native Release result

Swift 6.2.4 native Metal Release built and launched successfully. The ordinary
scene kept its light/shadow/SSAO/FXAA settings and measured a median **59.98 FPS**
(last twenty native frame intervals, range 58.90–61.37). The Release crowd control
measured 15.87 FPS; the final LOD-only control measured 17.01 FPS under variable
background load, with roughly 107k submitted camera triangles versus 189k.
The combined prepass/GPU control did not show a reliable FPS win in this open
scene. Use Hi-Z for occluder-heavy workloads and compare to its CPU control.
The final palette/envelope/cadence changes passed the full 1263-test run again.

Artifacts: `dist/performance/native-frame-summary.json`, native runtime sample
logs, and PNG/count/timing controls under `dist/captures`. Compiler-dependent
and loaded-host results are deliberately kept separate from the browser result.

## Final browser A/B

With both task compilers finished, native SkeletalGarden stopped and the same
active 1280x720 in-app browser viewport, Debug measured median **5.71 FPS**
and final Release measured median **25.71 FPS** (range 24.83–27.11), approximately
**4.5x**. Both samples retain the ordinary lights, shadows, SSAO and FXAA; the
Release also uses character LOD. The test compares the delivered configurations,
not an isolated claim for any single optimization. The final scene rendered both
characters, props and landscape without WebGPU validation errors.

Browser 60 FPS is not established. GPU Hi-Z/compaction runs on Metal; browser
WebGPU currently keeps CPU visibility. Actual samples and conditions are in
`dist/performance/browser-baseline-active.json` and `browser-release-final.json`.

Later in-app samples dropped to about 14 FPS after panel activity/viewport
changes, despite no compilation. The 25.71 figure is the measured A/B interval,
not a guarantee of sustained browser FPS; focus/throttling and desktop load
remain relevant. The native frame sample remained approximately 60 FPS.
