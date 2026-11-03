# Sponza: missing geometry, texture detail and DLSS — 2026-11-03

## Cause and changes

The previous PT asset preparation used `gltfpack -si 0.015 -se 1` with permissive
simplification. A 100% relative error tolerance allowed whole architectural
surface groups to disappear: `floor_01`, `brickwall_01`, `brickwall_02` and
`column_brickwall_01` had no triangles in the generated model. This was an asset
preparation defect, not acceptable path-tracing noise. The original full-scene
assets were unaffected.

The corrected profile limits relative error to 1%, spends a 2.8% triangle target
on architecture and 0.3% on ivy, and rejects loss of any source material group.
The result contains 122,286 source triangles within the existing 131,072 budget:
114,042 building triangles and 8,244 ivy triangles. All 28 building material
groups and both ivy groups remain. The floor has 350 triangles. It remains an
explicit LOD and does not restore the original 8.81M triangles in the software BVH.

The demo now requests 512×512 PT material tiles instead of 128×128. The engine
default stays 128 for existing scenes; the new Codable setting `textureTileSize`
supports bounded 128/256/512 tile sizes. Atlas allocation and shader addressing
use the selected size, and a size change rebuilds the atlas and resets history.
The maximum atlas extent is 8192×8192. This uses more GPU memory and still does
not retain original 4K texture detail. DLSS cannot restore discarded source data.

The demo connects the existing native Dawn/D3D12 DLSS Super Resolution bridge
through the camera's temporal upscaling settings. DLSS is enabled on a supported
device; Quality uses 2/3 input scale and Performance 1/2. PT traces at the temporal
input resolution rather than reducing resolution a second time. Depth and motion
guides use the same LOD. The status line reports actual encoded and fallback
frames. Unsupported devices leave DLSS unavailable. This adds neither Frame
Generation nor Ray Reconstruction; the integration is described in
[DLSS.md](../DLSS.md) and uses [NVIDIA NGX](https://github.com/NVIDIA/DLSS).

A separate shadow-casting point light flies through the upper gallery on a
12-second orbit. It starts enabled and has an independent toolbar switch. Its
range is 10 metres and intensity 25. The local raster shadow atlas retains its
four-source limit and selects nearby lights; PT shadow rays include all valid
shadow-casting lights independently of this limit. It changes illumination without moving
geometry or rebuilding the BVH. Disable the flight to inspect static accumulation:
light movement intentionally invalidates the static PT history. Existing lighting
profiles disable flight and DLSS to keep their explicit stationary-light cases.

## Validation

The native bridge smoke test processed 12 frames at 1280×720 → 1920×1080 with zero
GPU errors on the RTX 4070. The bridge and Swan use the same hashed Dawn library.
The isolated release build succeeded. The final focused native run passed 25 tests in
7 suites, including DLSS movement/resize/DLAA/reset, path tracing, camera controls,
the flying-light orbit and temporal history/integration tests.
The standard `script/validate_webgpu.sh` also passed its focused 19-test renderer
filter (`PathTracing|DLSS|Temporal3D`), including fresh shader conversion and actual
GPU output. The available Windows toolchain was Swift 6.3.1 rather than 6.3.2;
the pinned Tint hash/reader/writer check passed.

The interactive run confirmed the restored gallery floor, walls and columns,
122,281 nondegenerate traced triangles, 14 lights with flight enabled, and actual
1260×594 → 1890×890 DLSS evaluation. It also exposed a temporal lifecycle bug:
offscreen display-ring backpressure deleted the NGX feature and reset diagnostics
on every skipped view. Source-camera extraction now records cameras requesting
temporal reconstruction before the skip guard. Temporal cleanup retains their
backend features, uniforms and counters until temporal rendering is disabled or
the camera is removed. A real-DLSS regression checks feature identity across the
skip, resumed encoded-frame progress and cleanup after disabling reconstruction.
The final 25-test run passed after this fix (15.893 seconds). The standard-script
19-test run above preceded the additional DLSS lifecycle regression.
In the final demo, the DLSS counter reached 2361 with zero fallback frames while
the log showed one NGX feature creation for that unchanged resolution. Turning
the flying-light toolbar switch off changed the traced light count from 14 to
13 and allowed static accumulation to reach 128. The floor and columns remained
visible with readable material patterns. This is an interactive correctness
check, not a controlled FPS measurement.
The Performance button also switched actual DLSS input to 945×445 for the same
1890×890 output, with zero fallback frames. The demo was left open in Performance
mode with the flying-light switch enabled for further testing.

A new real-GPU regression changes the atlas from 128 to 512 using a 512-pixel
striped source texture. It checks the actual allocated atlas, reads back its
pixels to verify fine stripes survive, and verifies that accumulation restarts.
Fresh shader conversion is exercised by the PT tests. Asset receipts record
triangle counts by material and hashes of the generated geometry.

Evidence lives in [SponzaQuality-2026-11-03](../../Evidence/Meshlets/SponzaQuality-2026-11-03).
The older [lighting measurements](SponzaLightingPerformance-2026-11-03.md) used the
old LOD and 128-pixel atlas; they are not performance results for this corrected
quality configuration. No FPS improvement is claimed from the bridge smoke test.
