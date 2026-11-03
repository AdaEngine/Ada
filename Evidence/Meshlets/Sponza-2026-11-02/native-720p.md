# Sponza baseline samples

Backend: webgpu; 1280×720; 60 warmup + 600 measured frames; 3 alternating A/B pairs.

Completion: `native-queue-throughput-window-v1`, 90-frame submission windows.

Wall is the median of all per-round drain-inclusive frame averages. Window p95 describes drained window averages, not individual frame latency. Update is CPU-side app-update wall time, not GPU time. Extraction, list preparation (including uploads) and main-node wall time are separate diagnostics at the route end, outside throughput timing. Import, geometry digest, PNG readback and diagnostics are excluded. Census is CPU coarse visibility/batching at the final pose, before GPU Hi-Z. No best-round selection.

| preset | quality | route | Hi-Z | wall ms | window median / p95 ms | update median ms | extraction / lists / node ms | end batches | end triangles | index ceiling MiB/slot |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sponza-base | geometry | atrium | False | 2.129 | 1.850 / 3.505 | 1.634 | 0.139 / 0.105 / 0.954 | 168 | 1651925 | 18.905 |
| sponza-base | geometry | atrium | True | 2.541 | 2.372 / 3.780 | 2.062 | 0.140 / 0.109 / 1.335 | 168 | 1651925 | 18.905 |
| sponza-base | geometry | ground-floor-corridor | False | 2.399 | 2.257 / 3.894 | 2.024 | 0.149 / 0.163 / 1.318 | 274 | 2458924 | 28.140 |
| sponza-base | geometry | ground-floor-corridor | True | 3.012 | 2.830 / 4.067 | 2.604 | 0.149 / 0.170 / 1.970 | 274 | 2458924 | 28.140 |
| sponza-base | geometry | upper-gallery | False | 2.341 | 2.102 / 3.494 | 1.927 | 0.149 / 0.178 / 1.490 | 309 | 3010425 | 34.452 |
| sponza-base | geometry | upper-gallery | True | 2.640 | 2.639 / 4.079 | 2.467 | 0.157 / 0.187 / 2.165 | 309 | 3010425 | 34.452 |
| sponza-base | pbr | atrium | False | 6.319 | 6.175 / 7.853 | 5.822 | 0.163 / 0.116 / 2.428 | 170 | 1659097 | 18.987 |
| sponza-base | pbr | atrium | True | 6.907 | 6.490 / 8.747 | 6.325 | 0.149 / 0.118 / 2.890 | 170 | 1659097 | 18.987 |
| sponza-base | pbr | ground-floor-corridor | False | 7.455 | 7.623 / 8.345 | 7.188 | 0.166 / 0.174 / 3.721 | 278 | 2467064 | 28.233 |
| sponza-base | pbr | ground-floor-corridor | True | 8.169 | 8.255 / 9.564 | 7.961 | 0.145 / 0.177 / 4.480 | 278 | 2467064 | 28.233 |
| sponza-base | pbr | upper-gallery | False | 7.673 | 7.777 / 9.969 | 6.984 | 0.165 / 0.194 / 4.192 | 313 | 3018565 | 34.545 |
| sponza-base | pbr | upper-gallery | True | 8.203 | 8.191 / 10.442 | 7.610 | 0.157 / 0.194 / 5.005 | 313 | 3018565 | 34.545 |
| sponza-ivy | geometry | atrium | False | 2.110 | 1.854 / 3.394 | 1.665 | 0.160 / 0.108 / 0.971 | 170 | 6717483 | 76.875 |
| sponza-ivy | geometry | atrium | True | 2.889 | 2.605 / 4.736 | 2.154 | 0.155 / 0.115 / 1.532 | 170 | 6717483 | 76.875 |
| sponza-ivy | geometry | ground-floor-corridor | False | 2.737 | 2.264 / 4.315 | 2.035 | 0.158 / 0.175 / 1.459 | 276 | 7524482 | 86.111 |
| sponza-ivy | geometry | ground-floor-corridor | True | 2.869 | 2.808 / 3.868 | 2.634 | 0.167 / 0.212 / 2.029 | 276 | 7524482 | 86.111 |
| sponza-ivy | geometry | upper-gallery | False | 2.646 | 2.222 / 4.433 | 1.994 | 0.175 / 0.215 / 1.879 | 311 | 8075983 | 92.422 |
| sponza-ivy | geometry | upper-gallery | True | 3.132 | 3.054 / 4.672 | 2.583 | 0.148 / 0.188 / 2.247 | 311 | 8075983 | 92.422 |
| sponza-ivy | pbr | atrium | False | 6.452 | 6.155 / 8.078 | 5.992 | 0.144 / 0.116 / 2.455 | 172 | 6724655 | 76.958 |
| sponza-ivy | pbr | atrium | True | 7.326 | 6.818 / 9.065 | 6.452 | 0.152 / 0.119 / 3.014 | 172 | 6724655 | 76.958 |
| sponza-ivy | pbr | ground-floor-corridor | False | 7.554 | 7.724 / 8.422 | 7.333 | 0.153 / 0.186 / 3.748 | 280 | 7532622 | 86.204 |
| sponza-ivy | pbr | ground-floor-corridor | True | 8.381 | 8.311 / 9.885 | 8.070 | 0.160 / 0.183 / 4.604 | 280 | 7532622 | 86.204 |
| sponza-ivy | pbr | upper-gallery | False | 7.510 | 7.382 / 8.613 | 7.102 | 0.158 / 0.194 / 4.162 | 315 | 8084123 | 92.515 |
| sponza-ivy | pbr | upper-gallery | True | 8.267 | 8.417 / 9.473 | 7.823 | 0.158 / 0.196 / 5.009 | 315 | 8084123 | 92.515 |

GPU pass timestamp samples: 0. An empty set does not establish GPU pass cost or prove a geometry bottleneck. Index ceilings omit the resource ring, scratch and static cluster data; they are not measured peak VRAM.
