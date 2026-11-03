# Meshlet P0 baseline samples

Backend: webgpu; 1280x720; 60 warmup / 90 measured frames per round; 3 alternating pairs; resource ring 3; submission window 90 frames.

Completion protocol: `native-queue-throughput-window-v1`.

`wall` is the median of drain-inclusive per-round frame averages. `window` median/p95 are GPU-drained window averages per frame, not individual frame-latency percentiles. `update` is CPU-side app-update wall time (including submission), not exclusive CPU encode time. Extraction, list preparation and main-node wall time run in a separate diagnostic phase; uploads are included in list time and the main node includes preparation/encode/submission. No texture readback is included in throughput timing. GPU pass samples, when available, come from a separate serialized phase. No best-round selection.

| workload | Hi-Z | wall ms | window median / p95 ms | update median ms | extraction median ms | list median ms | main node median ms | batches | batch sizes | singleton triangles | index ceiling MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| partial | False | 1.058 | 1.058 / 1.177 | 0.908 | 0.114 | 0.005 | 0.191 | 1 | 1: 1 | 32768 | 0.375 |
| partial | True | 1.245 | 1.245 / 3.493 | 1.080 | 0.111 | 0.005 | 0.351 | 1 | 1: 1 | 32768 | 0.375 |

Geometry census is measured after CPU coarse visibility/LOD/batching, before GPU Hi-Z. Singleton triangle counts are a potential workload, not full material/deformation eligibility. The index ceiling is one output slot only; ring, scan scratch and static meshlet data add memory.
