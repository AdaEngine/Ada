# Sprite GPU instancing

`SpriteDrawData` defaults to `.automatic`: devices advertising
`RenderDevice.supportsInstancedVertexInputs` use the instanced pipeline.
Metal and WebGPU advertise this capability; OpenGL, headless and other devices
retain the expanded-vertex path through the protocol's false default.

To select the production reference path, configure the render world's resource
after installing SpritePlugin and before running frames:

```swift
var drawData = SpriteDrawData.defaultValue
drawData.renderingMode = .batched
renderWorld.insertResource(drawData)
```

Each quad emitted by SpriteGeometry becomes one 96-byte instance. A shared
four-corner quad and six indices are uploaded once. Instance records contain
the transformed plane origin/basis, tint and four cropped atlas UVs. Anchors,
fit/fill, nine-slice, partial tiling, flips and reflected/composed transforms
reuse the production layout path. Expanded vertices/indices are not generated
on the instanced path.

Only adjacent sprite items sharing GPU texture and sampler join a draw. Text,
Mesh2D, tile chunks and other draw passes separate batches, including when they
share an entity ID with a Sprite. Leading render items carry their actual quad
ranges; followers do not draw. A later batch offset binds a different section
of the instance buffer. Primitive/painter order is preserved rather than sorting
all sprites by texture.

Instance GPU buffers rotate using the renderer's configured frames-in-flight
budget. CPU array capacity, GPU buffer capacities and pipelines are retained.
Shared quad/index buffers stay immutable after upload. Resources belong to the
render world; separate worlds do not share mutable instance buffers.

## Validation — 2026-10-10

Swift 6.3.2/macOS: 196 focused Sprite/Render/tilemap/reflection tests in 32 suites
passed, including fallback geometry, instance layout/reconstruction, invalid
layouts, painter boundaries and repeated render IDs. A separate real Metal
process passed pixel-identical comparisons against `.batched` with both tile-map
chunk and per-tile paths. This covers atlas UVs, alpha click-through, all image
modes and all eight tile orientations. An additional real Metal workload verifies
20,000 sprites, equal output pixels, one draw and GPU buffer ring reuse.

The warmed workload uses 12 frames, discarding the first four. Preparation CPU
includes the production SpriteRenderSystem and GPU uploads. GPU numbers are
completed command-buffer timestamps, with serialized submissions/readback rather
than display FPS. The measurements are local to this scene/hardware/load:

| Configuration | Path | CPU preparation | Per-frame upload | Draws | GPU command |
| --- | --- | ---: | ---: | ---: | ---: |
| Debug | Expanded | 75.62 ms | 3,680,000 bytes | 1 | 0.339 ms |
| Debug | Instanced | 35.15 ms | 1,920,000 bytes | 1 | 0.672 ms |
| Release | Expanded | 27.69 ms | 3,680,000 bytes | 1 | 1.161 ms |
| Release | Instanced | 12.01 ms | 1,920,000 bytes | 1 | 1.235 ms |

Release used a temporary minimal SwiftPM test package importing the production
Sprite/Render modules and the same benchmark source. The root Release test build
was blocked by a Swift compiler crash lowering AdaUI's LiquidGlassTabBarControls;
no AdaUI code was changed. That temporary package resolved dependencies independently
of the root lockfile. Debug A/B and Release results should not be used to infer
cross-configuration GPU gains. Upload falls 47.8% and Release preparation improves
2.31x in this workload; GPU execution is not faster and draws were already batched.

Run the native checks separately from headless suites:

```sh
ADAENGINE_SPRITE_SAGA_SMOKE=1 \
swift test --filter SpriteMetalRenderingTests/rendersLayoutsAndPickingWithSAGA

ADAENGINE_SPRITE_INSTANCING_BENCHMARK=1 \
ADAENGINE_SPRITE_INSTANCING_REPORT=/tmp/sprite-instancing-report.json \
swift test --filter SpriteInstancingMetalTests
```

Use an isolated scratch path/module cache matching the toolchain.

Native WebGPU now passes production pixel A/B checks for the chunk and per-tile
paths, including alpha picking, padded texture readback and tile occlusion.
The developer command also verifies host-tool discovery, real fresh GLSL → SPIR-V
→ Tint WGSL compilation and WGSL binding reflection: six tests in four suites pass.

The separate `Examples/Technical/SpriteInstancingValidation` app exercises the same production
SpriteRenderSystem / SpriteDrawPass / shaders on all three validated runtimes:

| Runtime | Backend | Result |
| --- | --- | --- |
| macOS native | WebGPU / Dawn 147 | Layout/tile/reference pixels identical; shadow checks pass |
| Browser WASM / Codex in-app browser | WebGPU | Ten frames, 1242 quads, eight draws; reference pixels identical and control pixels pass |
| iPhone 17 Pro Simulator / iOS 26.3 | Metal | App launched; visible PASS and identical pixels |
| Physical iPad8,1 / iPadOS 26.5 | Metal | App installed/launched; report retrieved from its own data container confirms PASS |

The portable fixture covers all image modes, atlas borders, flips, anchors,
reflection/rotation, alpha compositing, texture changes and a contiguous 1200-sprite
run. It renders five expanded and five instanced frames. Known red/blue/green
pixels must also match, so two empty or invalid renders cannot satisfy the check.
It tests rendering correctness, not mobile performance or Editor inspector UI.
Android and non-Metal fallback GPU execution remain unverified.

The browser run exposed and fixed two export/runtime defects: local Swan was
omitted from BridgeJS skeleton discovery, and the WGSL reflection parser did not
recognize Tint's unsigned `@group(0u)` / `@binding(2u)` values. The parser is now
shared with native regression tests, including a fresh real Tint-generated UBO.
Browser asynchronous texture readback uses the existing owned buffer mapping path
and strips padded rows, enabling the same pixel checks as native backends.

## Current validation

Run `script/validate_gpu.sh` with Swift 6.3.2 for native SAGA pixel checks.
The browser export links WESL to WGSL with SAGACompiler and ships the SAGA WebGPU
host. The validation table above records the pre-cutover results.
