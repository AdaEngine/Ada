# Hierarchical meshlet LOD and shadow evidence

Interpretation: [implementation and measurements](../../../Documentation/Performance/MeshletLODAndShadows-2026-11-03.md).

Final renderer: Windows, RTX 4070, Dawn D3D12, Swift 6.3.1; coalesced 64-thread cluster scatter, adaptive CPU/GPU cut, independent temporal guides. Engine defaults remain opt-in. Metal hardware and browser acceptance are open.

- `validate-meshlet-lod-coalesced.log.gz`: final renderer release build, fresh Tint conversion and 63 passing GPU/CPU tests in 19 suites.
- `validate-meshlet-lod-cache-tests.log.gz`: extra focused cache/LOD run, 12 passing tests in 6 suites. Other validation logs are earlier runs; overlapping test counts are not summed.
- `validate-meshlet-lod-sampler-build.log.gz`: demo-only safe post-interval sampling build.
- `meshlet-lod-benchmark.json.gz`, `meshlet-lod-benchmark-summary.json`: final 18-case LOD Off/2/8 comparison at fixed SceneView size, 2048/1024 shadows and 80-metre sun coverage. Publication intervals and CPU encode are not GPU timestamps/native Present. Readback is outside timing at a frame safe point.
- `before-coalesced-scatter-*`: earlier scatter implementation at 30-metre sun coverage; not an identical-settings final A/B.
- `rejected-window-resize-benchmark.json.gz`: intentionally rejected profile with changing image resolution.
- Four `*.meshletlod.json.gz` receipts: pinned native tool/source provenance, source dependencies, sidecar SHA-256, per-part original/coarsest counts and hierarchy bounds.
- `meshlet-lod-fine-map.png`, `meshlet-lod-coarse-map.png`, `meshlet-lod-temporal-guides.png`: actual GPU regression captures.
- `local-shadow-precision-*.png`: actual GPU thin-caster shadow regression captures.
- `sponza-*.png`: final interactive executable captures after timing.
- `source-hashes.json`: task-related source SHA-256; unrelated dirty Editor/UI files excluded.
- `evidence-hashes.json`: evidence hashes, excluding itself.

Reproduce validation with the environment and commands in [the previous evidence README](../Implementation-2026-11-03/README.md), adding `LocalShadowPrecision|ShadowFiltering` to `ADAENGINE_WEBGPU_TEST_FILTER`. Prepare all source-adjacent LOD files using `script/prepare_meshlet_lod.py`; no simplifier is linked into runtime.

For the final benchmark use `ADAENGINE_SPONZA_PROFILE_MESHLET_LOD=1` and an absolute `ADAENGINE_SPONZA_PROFILE_OUTPUT`; see [the demo instructions](../../../Demos/Sponza/README.md). The helper `summarize_meshlet_lod.py` accepts decompressed raw JSON and checks 18 cases, identical dimensions/quality and actual LOD GPU activity.
