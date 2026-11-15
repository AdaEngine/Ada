# Spatial upscaling

`renderUpscaling(.spatial(renderScale:))` requests lower-resolution window
rendering on devices whose backend provides a spatial upscaler. The scale is
linear and clamped to `0.5...1`. A scale of `0.75` corresponds to approximately
56% of the output pixel count.

SAGA currently presents ordinary cameras at native resolution for both
`.disabled` and `.spatial`. This also applies to the default 0.75 request on iOS.
Pixel-perfect cameras retain their own nearest-neighbor presentation.

For a 3D camera, use the portable temporal reconstruction path to render below
output resolution on SAGA:

```swift
camera.temporalUpscaling = TemporalUpscalingSettings(renderScale: 0.75, method: .portable)
```

The portable method uses scene history and motion vectors. At a scale of 1 it
provides temporal antialiasing. The compositor supplies the render size for
cameras using visionOS foveation.

Run `script/validate_gpu.sh` to exercise render sizing and the native SAGA
renderer.
