# Skeletal Garden WebGPU validation

Verified on 2026-10-05, macOS / Apple M3 Pro. This report covers the current
uncommitted source changes on `main`, after the 3D merge.

## Build and browser proof

- Swift 6.3.2 host + `swift-6.3.2-RELEASE_wasm`, debug export with the
  AdaWebExportPlugin and separate host/WASM scratch directories: passed.
- Reactor ABI: `memory` and `__main_argc_argv` exported; `_start` absent.
- Export contains the runtime, BridgeJS, WASI filesystem resources, GLBs and
  offline-transpiled WGSL. Served locally at `http://127.0.0.1:8765`.
- Codex in-app browser: actual backend log `webgpu`; both skins / 43 joints and
  terrain loaded. Rendered robots, props, landscape, colored local lighting and
  directional/local shadows visibly verified.
- Key 8 disables/restores local illumination; key 9 removes local shadows.
  Both controls visibly change the rendered scene. WASD input also moves the
  player and updates the camera/pose. No new WebGPU validation
  errors after the final browser reload and these controls.

## Native WebGPU proof

- Swift 6.3.2 native debug build with `ADAENGINE_WEB_EXPORT=1`: passed.
- Actual backend `webgpu`, Dawn adapter using the M3 Pro Metal driver.
- GPU render-target readback shows the complete scene, colored point/spot
  illumination, skeletal meshes and shadows. Capture:
  `dist/captures/native-webgpu/frame-50.png`.
- The standard local-light capture records two point lights, one spot light and
  thirteen local-shadow projections. GPU timestamps are unavailable on this
  backend; no performance comparison is inferred from these captures.

## Metal control

The native Metal debug build also passed. A `--capture-quality` launch without
`--local-lights` visibly includes colored point/spot illumination and local
shadows (`dist/captures/quality/frame-50.png`). The backend log confirms `metal`;
this was run after the WebGPU captures to exercise the shader-cache language
check across backend switches.

## Fixes exercised

Ordinary launches now include local lights; `--daylight` selects the original
sunlight scene. Async GLB loading avoids synchronous WASM asset loading. WASM
bundle URLs retain their complete filenames and the executable uses the reactor
linker settings. BridgeJS origin/enum/mask values match the browser bindings.
Descriptor-set merging unions shader-stage visibility instead of overwriting it.
Native compilation uses WGSL through Tint and rejects cached shaders for another
backend language. Winding matches Metal defaults and fullscreen presentation
avoids culling. Browser atlas passes apply viewport transforms through
JavaScriptKit because the Swan wrapper does not yet expose setViewport. WebGPU readback maps a GPU-copy staging buffer asynchronously.
Browser/native GPU diagnostics report validation failures.

## Regression checks and limits

The full Swift Testing run passed: 1256 tests in 222 suites. The focused run
passed 18 tests in eight suites: demo lighting defaults,
owned buffer readback, shared shader bindings, local-light math/extraction,
shadow/camera isolation, sparse vertex slots and render-quality integration.

MetalFX is Metal-only and takes the spatial path on WebGPU. This validation does
not establish Android, Windows, Safari/Chrome compatibility, release-build
performance or physical mobile-device behavior. The WASM export is a debug build.

Changed runtime/demo/test files pass strict SwiftLint. The exporter file retains
63 pre-existing lint violations (unchanged by the diagnostic JavaScript block).

Completed task scratch builds were removed after disk space ran low. The final
web export, PNG captures, staged Metal application and build/test logs remain.
The shared repository `.build` and unrelated working changes were preserved.
