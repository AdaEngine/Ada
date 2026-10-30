# DLSS through native WebGPU / Dawn

Windows DLSS Super Resolution and DLAA use the existing Dawn D3D12 backend.
The engine has no additional DirectX renderer. A small optional C++ target,
`CWebGPUDLSS`, calls NVIDIA NGX with shared textures on Dawn's selected device.
Browser WebGPU does not expose these native extensions.

## Build

With the Windows toolchain and the matching Swan/Dawn artifact already available:

```powershell
python script/build_dlss.py --smoke
swift build
```

The preparation script pins NVIDIA/DLSS to
`9981c6350dc58c0ce21f024fd65e31e851c31689`, builds the bridge in
`.build-tools/dlss-interop`, and checks actual GPU output. The generated
`build.json` enables the optional SwiftPM target on Windows. It also records
the Dawn library hash: the bridge and Swan must use the same Dawn binary.
`ADAENGINE_DAWN_PATH` and `ADAENGINE_DLSS_SDK_PATH` can select explicit local
artifacts. No downloaded SDK binaries are added to source control.

Stage the signed runtime and license beside each executable:

```powershell
python script/build_dlss.py --stage-runtime path/to/bin
```

`nvngx_dlss.dll` and `NVIDIA-DLSS-LICENSE.txt` come from the pinned SDK.
The custom-engine project GUID is a development identity, not an
NVIDIA-assigned application ID.

## Frame path

1. Render the scene and unjittered current-to-previous motion vectors using
   the ordinary WebGPU pipelines; submit this command segment.
2. Copy HDR color on the GPU. A WebGPU pass packs hardware depth, two-channel
   motion and the existing transparency/reactive coverage into shared textures.
3. Release Dawn access with `SharedTextureMemory.EndAccess`. Export its fences
   and enqueue D3D12 queue waits before touching these resources with NGX.
4. Evaluate DLSS in a native command list on Dawn's D3D12 queue. Transition
   owned shared textures back to COMMON and signal the imported native fence.
5. Reacquire the result through Dawn, copy it into the ordinary HDR resolve
   texture, then continue tone mapping, output depth, camera effects and HUD.

The bridge never obtains undocumented native pointers from ordinary Dawn
textures. It owns the shared resources and imports them through the public
`SharedTextureMemoryD3D12Resource` and `SharedFenceDXGISharedHandle` extensions.
The native-only `allow_unsafe_apis` Dawn toggle is needed to expose them.

HDR input uses NGX auto exposure. Motion is normalized UV displacement, scaled
to input pixels for NGX. Depth is conventional hardware depth, not reversed Z.
Camera cuts, changes of projection/resolution and explicit reset generations
reuse the engine's temporal history reset rules. Each camera has its own NGX
feature. Three command allocators are reused only after their GPU fence completes.
Bindings/views are cached while the source textures remain the same.

No frame pixels cross the CPU during reconstruction. There are extra GPU color
copies and a packing pass; this integration does not guarantee an FPS increase
in CPU-bound or low-resolution workloads. Frame Generation and Ray Reconstruction
are outside this implementation.

## Failure and validation

The selected adapter, enabled Dawn features and NGX capabilities are checked.
Unsupported adapters leave temporal reconstruction unavailable. A failed NGX
evaluation disables the DLSS device for that session; the game can then restore
native resolution. `ADAENGINE_DISABLE_DLSS=1` forces this unavailable path.
The current reactive mask covers the surfaces written by the existing motion
pass; it is not a complete per-particle velocity solution.

The Windows GPU test `Render3DGPUTests/DLSS` exercises real reconstruction,
camera movement, comparison with native output, render-scale changes, DLAA,
history reset and disabling temporal rendering. Enable it with
`ADAENGINE_DLSS_TESTS=1` and run `script/validate_webgpu.sh` with a task-local
`ADAENGINE_WEBGPU_SCRATCH`. The script stages the matching NVIDIA runtime before
running the tests. `Temporal3DHistoryTests` and `Temporal3DIntegrationTests`
cover history, projection, transparent motion and unsupported-backend behavior.

Sources: [NVIDIA NGX SDK](https://github.com/NVIDIA/DLSS),
[NVIDIA's D3D12 integration example](https://github.com/NVIDIA-RTX/Donut/blob/main/src/render/DLSS-DX12.cpp).
