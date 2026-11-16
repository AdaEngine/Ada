# DLSS Upscaling

Render a 3D view below its output resolution and reconstruct it with NVIDIA DLSS Super Resolution, or denoise a
path-traced view with DLSS Ray Reconstruction. DLSS is optional: without it a camera uses the portable temporal
reconstruction that ships with the engine, and nothing else changes.

## Requirements

- An NVIDIA GeForce RTX GPU with a current driver, running the Vulkan renderer (Windows today).
- The NVIDIA DLSS SDK. Its license is NVIDIA's, so AdaEngine never contains or downloads it. Clone
  `https://github.com/NVIDIA/DLSS` yourself and accept its terms before using it.

## Set up the runtime

Build the small AdaEngine bridge once against your copy of the SDK. It writes `adaengine_ngx.dll` and copies the NGX
libraries next to it:

```bash
python ada_tool.py build ngx-bridge --sdk path/to/DLSS --output path/to/ngx
```

Point the engine at that folder with the `ADAENGINE_NGX_SDK_PATH` environment variable, or put the files next to the
game executable. Both the bridge and `nvngx_dlss.dll` must be in the same folder; ship `nvngx_dlssd.dll` too if you use
Ray Reconstruction. Only absolute folders are searched, never the current directory or `PATH`.

## Use it on a camera

Choose DLSS on the camera's temporal upscaling settings. `renderScale` is the ratio of internal to output resolution,
and the engine picks the closest DLSS preset:

```swift
camera.temporalUpscaling = .init(renderScale: 0.5, method: .dlss)
```

| Render scale | Preset |
| --- | --- |
| 1 | DLAA |
| about 0.67 | Quality |
| about 0.58 | Balanced |
| 0.5 | Performance |
| about 0.33 | Ultra Performance |

`.automatic` (the default) uses DLSS when it is available and the portable reconstruction otherwise. `.dlss` asks for
DLSS and falls back to `.portable` when it cannot run. `.portable` never uses DLSS; choose it to keep the portable
reconstruction on an RTX machine where the bridge is installed.

## Check what ran

DLSS initializes on the first frames after startup. Until it is ready, `.dlss` and `.automatic` cameras use the
portable reconstruction.
Read the `TemporalReconstructionStatuses` resource from the render world (the world that runs the render systems) to see, per camera, the method that was
requested, the method in effect, the DLSS preset and, when DLSS was not used, the reason:

```swift
if let status = statuses[cameraID], let reason = status.fallbackReason {
    print("DLSS not used: \(reason)")
}
```

## Ray Reconstruction

A path-traced view whose camera uses DLSS and traces at the DLSS input size is denoised and upscaled in one step by
Ray Reconstruction. Leave `pathTracing.denoiser` on `.automatic`, or set `.rayReconstruction` to request it. When it
cannot run, the view uses the portable denoiser and the path tracing statistics report why in `denoiserFallback`.

## Limits

- DLSS runs only through the Vulkan renderer on Windows; Linux, Metal and the web player use the portable
  reconstruction.
- Frame generation and the other DLSS features are not supported.
- A DLSS failure at run time turns DLSS off for every camera for the rest of the session and the portable
  reconstruction takes over. The frame that failed keeps whatever its output held.
