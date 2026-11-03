# Native meshlet v1 evidence

See [implementation report](../../../Documentation/Performance/MeshletsImplementation-2026-11-03.md) for interpretation and limitations.

- `validate-meshlets-seventh.log.gz`: final release build and 48 passing focused Swift Testing tests on Windows / RTX 4070 / Dawn D3D12. Sixth/fifth/fourth logs, where retained, are earlier development runs.
- `meshlet-benchmark-optimized.json.gz`: final 18-case full Sponza run, 1890×843; alternating disabled/CPU/GPU modes, gallery rotation and stationary outside, three rounds. SceneView publication intervals and CPU graph durations, not GPU timestamps.
- `meshlet-benchmark-optimized-summary.json`: per-run values and medians; `summarize_final_meshlets.py` accepts the decompressed raw JSON. GPU readback is one post-interval sample, separate from fast-path/fallback triangles.
- `meshlet-benchmark-optimized.stdout.log.gz` / `.stderr.log.gz`: startup, adapter, completion marker.
- `initial-serial-scan-benchmark.json.gz`: rejected slower prototype, not the final result.
- `meshlet-map-fixture.png`: actual native GPU test capture.
- `sponza-meshlet-map-gallery.png`, `sponza-meshlet-map-outside.png`, `sponza-meshlets-gpu-gallery.png`: live final executable; machine's external performance overlay is present. These captures were taken after timing, not during it.
- `test-meshlets-neighbors.log.gz` and `legacy-golden-comparison.json`: neighboring regressions and exact pre-existing image hash matches for four legacy golden mismatches. References were not rewritten.
- `source-hashes.json`: SHA-256 of task-related source/documentation inputs from the dirty worktree. Unrelated Editor/UI changes are not included.
- `evidence-hashes.json`: SHA-256 of evidence files, excluding itself.

Validation command (PowerShell environment, then Git Bash):

```powershell
$env:ADAENGINE_WEB_EXPORT='1'
$env:SWAN_LOCAL_DAWN='.build/benchmark-dawn-148.artifactbundle'
$env:ADAENGINE_WEBGPU_SCRATCH='D:/Development/AdaEngine/.build-codex/meshlets-p0'
$env:ADAENGINE_SWIFT_CONFIGURATION='release'
$env:ADAENGINE_SWIFT_JOBS='12'
$env:ADAENGINE_DLSS_TESTS='1'
$env:ADAENGINE_VALIDATE_SPONZA='1'
$env:ADAENGINE_WEBGPU_TEST_FILTER='Meshlet|Render3DDebugViewSettingsTests|PathTracing|DLSS|Temporal3D|SponzaCameraTests|WGPUCommandCompletion'
& 'C:/Program Files/Git/bin/bash.exe' script/validate_webgpu.sh
python script/test_prepare_meshlets.py
```

Demo measurement uses `ADAENGINE_SPONZA_PROFILE_MESHLETS=1`, an absolute `ADAENGINE_SPONZA_PROFILE_OUTPUT`, and prepared adjacent sidecars. See [demo instructions](../../../Demos/Sponza/README.md). Engine default remains disabled: final gallery timing regressed versus legacy, so performance rollout is not accepted. Metal hardware and browser acceptance remain open.
