# Meshlet P0 baseline samples

Backend: webgpu; 640x360; 60 warmup / 90 measured frames per round; 3 alternating pairs; resource ring 3; submission window 90 frames.

Completion protocol: `native-queue-throughput-window-v1`.

`wall` is the median of drain-inclusive per-round frame averages. `window` median/p95 are GPU-drained window averages per frame, not individual frame-latency percentiles. `update` is CPU-side app-update wall time (including submission), not exclusive CPU encode time. Extraction, list preparation and main-node wall time run in a separate diagnostic phase; uploads are included in list time and the main node includes preparation/encode/submission. No texture readback is included in throughput timing. GPU pass samples, when available, come from a separate serialized phase. No best-round selection.

| workload | Hi-Z | wall ms | window median / p95 ms | update median ms | extraction median ms | list median ms | main node median ms | batches | batch sizes | singleton triangles | index ceiling MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| partial | False | 1.061 | 1.061 / 1.240 | 0.928 | 0.132 | 0.005 | 0.200 | 1 | 1: 1 | 524288 | 6.000 |
| partial | True | 1.224 | 1.224 / 3.269 | 1.078 | 0.116 | 0.005 | 0.437 | 1 | 1: 1 | 524288 | 6.000 |

Geometry census is measured after CPU coarse visibility/LOD/batching, before GPU Hi-Z. Singleton triangle counts are a potential workload, not full material/deformation eligibility. The index ceiling is one output slot only; ring, scan scratch and static meshlet data add memory.
