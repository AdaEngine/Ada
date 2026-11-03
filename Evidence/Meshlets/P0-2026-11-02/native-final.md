# Meshlet P0 baseline samples

Backend: webgpu; 1280x720; 60 warmup / 90 measured frames per round; 3 alternating pairs; resource ring 3; submission window 90 frames.

Completion protocol: `native-queue-throughput-window-v1`.

`wall` is the median of drain-inclusive per-round frame averages. `window` median/p95 are GPU-drained window averages per frame, not individual frame-latency percentiles. `update` is CPU-side app-update wall time (including submission), not exclusive CPU encode time. Extraction, list preparation and main-node wall time run in a separate diagnostic phase; uploads are included in list time and the main node includes preparation/encode/submission. No texture readback is included in throughput timing. GPU pass samples, when available, come from a separate serialized phase. No best-round selection.

| workload | Hi-Z | wall ms | window median / p95 ms | update median ms | extraction median ms | list median ms | main node median ms | batches | batch sizes | singleton triangles | index ceiling MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| allVisible | False | 1.058 | 1.058 / 1.388 | 0.936 | 0.153 | 0.005 | 0.208 | 1 | 1: 1 | 524288 | 6.000 |
| allVisible | True | 1.571 | 1.571 / 3.952 | 1.081 | 0.119 | 0.005 | 0.349 | 1 | 1: 1 | 524288 | 6.000 |
| garden | False | 1.202 | 1.202 / 1.212 | 1.024 | 0.121 | 0.018 | 0.307 | 14 | 1: 14 | 1310 | 0.015 |
| garden | True | 3.980 | 3.980 / 3.996 | 1.204 | 0.118 | 0.018 | 0.483 | 14 | 1: 14 | 1310 | 0.015 |
| instances | False | 2.276 | 2.276 / 2.277 | 2.096 | 0.631 | 0.223 | 0.439 | 1 | 1600: 1 | 0 | 0.000 |
| instances | True | 4.081 | 4.081 / 5.079 | 2.404 | 0.611 | 0.256 | 0.717 | 1 | 1600: 1 | 0 | 0.000 |
| occluded | False | 1.053 | 1.053 / 3.274 | 0.956 | 0.119 | 0.007 | 0.223 | 2 | 1: 2 | 524300 | 6.000 |
| occluded | True | 1.240 | 1.240 / 4.004 | 1.131 | 0.147 | 0.007 | 0.475 | 2 | 1: 2 | 524300 | 6.000 |
| partial | False | 1.058 | 1.058 / 2.761 | 0.907 | 0.105 | 0.005 | 0.246 | 1 | 1: 1 | 524288 | 6.000 |
| partial | True | 1.245 | 1.245 / 3.608 | 1.058 | 0.116 | 0.005 | 0.423 | 1 | 1: 1 | 524288 | 6.000 |
| smallParts | False | 2.290 | 2.290 / 4.910 | 2.107 | 0.208 | 0.144 | 1.400 | 256 | 1: 256 | 3072 | 0.035 |
| smallParts | True | 2.805 | 2.805 / 2.837 | 2.604 | 0.191 | 0.147 | 1.690 | 256 | 1: 256 | 3072 | 0.035 |

Geometry census is measured after CPU coarse visibility/LOD/batching, before GPU Hi-Z. Singleton triangle counts are a potential workload, not full material/deformation eligibility. The index ceiling is one output slot only; ring, scan scratch and static meshlet data add memory.
