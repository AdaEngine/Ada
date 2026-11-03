# Sponza baseline samples

Backend: webgpu; 640×360; 60 warmup + 600 measured frames; 3 alternating A/B pairs.

Completion: `native-queue-throughput-window-v1`, 90-frame submission windows.

Wall is the median of all per-round drain-inclusive frame averages. Window p95 describes drained window averages, not individual frame latency. Update is CPU-side app-update wall time, not GPU time. Extraction, list preparation (including uploads) and main-node wall time are separate diagnostics at the route end, outside throughput timing. Import, geometry digest, PNG readback and diagnostics are excluded. Census is CPU coarse visibility/batching at the final pose, before GPU Hi-Z. No best-round selection.

| preset | quality | route | Hi-Z | wall ms | window median / p95 ms | update median ms | extraction / lists / node ms | end batches | end triangles | index ceiling MiB/slot |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sponza-base | geometry | atrium | False | 1.988 | 1.791 / 3.142 | 1.650 | 0.145 / 0.106 / 0.935 | 168 | 1651925 | 18.905 |
| sponza-base | geometry | atrium | True | 2.475 | 2.354 / 3.523 | 2.070 | 0.138 / 0.109 / 1.341 | 168 | 1651925 | 18.905 |
| sponza-base | geometry | ground-floor-corridor | False | 2.524 | 2.272 / 4.477 | 2.042 | 0.158 / 0.165 / 1.381 | 274 | 2458924 | 28.140 |
| sponza-base | geometry | ground-floor-corridor | True | 3.265 | 2.889 / 5.232 | 2.625 | 0.161 / 0.176 / 1.982 | 274 | 2458924 | 28.140 |
| sponza-base | geometry | upper-gallery | False | 2.551 | 2.270 / 5.060 | 1.948 | 0.160 / 0.182 / 1.513 | 309 | 3010425 | 34.452 |
| sponza-base | geometry | upper-gallery | True | 2.816 | 2.783 / 4.051 | 2.513 | 0.153 / 0.191 / 2.184 | 309 | 3010425 | 34.452 |
| sponza-ivy | geometry | atrium | False | 2.243 | 1.823 / 4.380 | 1.721 | 0.156 / 0.110 / 1.097 | 170 | 6717483 | 76.875 |
| sponza-ivy | geometry | atrium | True | 2.682 | 2.272 / 4.896 | 2.115 | 0.144 / 0.112 / 1.368 | 170 | 6717483 | 76.875 |
| sponza-ivy | geometry | ground-floor-corridor | False | 2.447 | 2.241 / 4.204 | 2.033 | 0.156 / 0.169 / 1.390 | 276 | 7524482 | 86.111 |
| sponza-ivy | geometry | ground-floor-corridor | True | 3.027 | 2.815 / 4.153 | 2.615 | 0.164 / 0.176 / 1.945 | 276 | 7524482 | 86.111 |
| sponza-ivy | geometry | upper-gallery | False | 2.424 | 2.122 / 4.485 | 1.941 | 0.159 / 0.177 / 1.570 | 311 | 8075983 | 92.422 |
| sponza-ivy | geometry | upper-gallery | True | 3.116 | 2.703 / 4.739 | 2.520 | 0.159 / 0.186 / 2.176 | 311 | 8075983 | 92.422 |

GPU pass timestamp samples: 0. An empty set does not establish GPU pass cost or prove a geometry bottleneck. Index ceilings omit the resource ring, scratch and static cluster data; they are not measured peak VRAM.
