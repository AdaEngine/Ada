# Gallery flight and long frames — 2026-11-03

The user reports approximately 40 FPS while flying in the upper gallery. Their new screenshot shows
46 FPS, 72% GPU load and irregular frame-time spikes. A fixed-camera average is insufficient to validate this case.

## Change and reproduction

The Sponza demo profiler now has repeatable moving-camera cases in addition to fixed views:

- Stationary gallery start pose.
- Translation 0–3 metres along gallery world X, keeping height, Z and orientation fixed.
- A full 360-degree yaw turn with a ±0.2-radian pitch sweep, keeping position fixed.

Motion repeats every six seconds of wall time, independently of FPS. It writes Transform/GlobalTransform
through the same ECS controls system used by the demo's interactive camera. The profiler records motion kind
and actual camera-write count. It does not synthesize native mouse messages or reproduce an arbitrary manual path.

Set `ADAENGINE_SPONZA_PROFILE_OUTPUT=<absolute JSON path>` and
`ADAENGINE_SPONZA_PROFILE_MOTION=1` to run all three cases. Use `rotation`, `translation` or `stationary`
for one case. Each case uses one second warmup and six seconds measurement, with three alternating pairs
of shadows on/off. Keep window size fixed. The run restores shadows and ends outside.

## Results

RTX 4070 / D3D12 / Swift 6.3.1, scene 3810 × 1883, original benchmark PBR profile, three shadow cascades,
Hi-Z disabled. Desktop and overlays remain active. These are SceneView publication intervals;
they are not GPU timestamps or a capture of the native window's Present events.

The first diagnostic used a limited ±0.55-radian yaw sweep; its results and parameters are retained separately.
Median throughput across its three runs:

| Case | Shadows on | Shadows off |
| --- | ---: | ---: |
| Stationary | 69.7 FPS | 98.0 FPS |
| Translation | 73.4 FPS | 96.6 FPS |
| Limited yaw sweep | 71.4 FPS | 101.7 FPS |

This limited movement did not reproduce a sustained 40 FPS state, so a second run covered every yaw direction.

| Full turn round | Shadows | Mean throughput | Lowest short-block throughput | P95 interval | Longest interval |
| --- | --- | ---: | ---: | ---: | ---: |
| 0 | on | 74.1 FPS | 41.9 FPS | 30.8 ms | 226.5 ms |
| 1 | on | 70.2 FPS | 38.0 FPS | 32.7 ms | 229.9 ms |
| 2 | on | 74.4 FPS | 35.8 FPS | 33.6 ms | 240.8 ms |
| 0 | off | 82.2 FPS | 34.0 FPS | 36.7 ms | 250.6 ms |
| 1 | off | 78.9 FPS | 50.6 FPS | 38.4 ms | 205.0 ms |
| 2 | off | 76.8 FPS | 34.6 FPS | 38.6 ms | 256.8 ms |

Short blocks are consecutive interval groups whose summed duration first reaches 500 ms; the final partial
block is omitted. This is not a sliding-window minimum or evidence of sustained 40 FPS for the whole route.
Each measured moving case performed 473–694 camera writes in the first run and 500–612 in the full-turn run.
The long frames demonstrate why average or last-frame numbers alone conceal the reported symptom.

## Findings and limits

CPU graph diagnostics from the first run put the main pass at approximately 3.9–4.7 ms and directional
shadows at 3.5–4.0 ms. These are CPU preparation/encoding wall times, not GPU execution times.
Turning shadows off helps the baseline throughput but does not remove the long frames in the full turn.
No source change to the engine renderer or quality reduction was made in this investigation.

Windows GPU Process Memory counters sampled the full-turn process for 43 seconds after assets were ready:
dedicated usage 7.404–7.841 GiB (median 7.583), shared usage approximately 0.111 GiB throughout.
The earlier limited-motion run also had stable shared usage around 0.19 GiB. This gives no observed jump
into shared memory; it is not proof that the process stays within its DXGI residency budget.

Source inspection found camera-independent mesh extraction caching. Visibility lists and directional
shadow cascades are prepared every frame even when stationary. A camera-triggered full mesh cache flush
was not found. Native captured mouse input still differs from the scripted motion and has not been isolated.

The long-frame symptom is reproduced; the root cause and sustained manual-flight 40 FPS state are not
fully localized. Next capture should correlate native Present, CPU frame stages, GPU pass timestamps,
queue completion and DXGI residency on the same timeline. Meshlet benefit should be evaluated against
this moving route and its interval tails, alongside fixed-camera baselines.

## Validation and evidence

Release build with tests passed. All four Sponza camera tests passed, including motion periodicity,
finite-time handling, corridor bounds and no camera roll. The live run recorded nonzero camera writes
for every moving case and zero writes for the stationary control. No engine/shader code changed.

Raw compressed JSON profiles, per-second process-memory samples, summaries, logs and source hashes:
[Evidence/Meshlets/SponzaMotion-2026-11-03](../../Evidence/Meshlets/SponzaMotion-2026-11-03).
The short-sweep parameters identify the earlier diagnostic implementation; final source hashes identify
the full-turn implementation. Earlier benchmark evidence remains unchanged.
