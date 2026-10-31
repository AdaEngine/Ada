# Environment color correction

On a camera's **Environment 3D** component, open **Color Correction** and choose
**Curves** or **LUT**. **Disabled** bypasses both. **Correction Strength** blends
the result with the original image: 0 leaves it unchanged, 1 applies the full look.
Saturation and contrast remain independent controls under Color Grading.

## Curves

Select Master RGB, Red, Green or Blue. Add a point and drag it on the graph:
left controls shadows, right controls highlights; raising a point raises that
channel's output. Remove an interior point with − Point, or reset the selected
channel with Reset Curve. A drag is one scene history edit. Curves and channel
settings survive saving and reopening the scene and switching correction modes.

```swift
var environment = Environment3D()
environment.colorCorrectionMode = .curves
environment.colorCorrectionStrength = 0.8
environment.postProcess.colorGrading.curves.master = ColorCurve3D(points: [
    .init(0, 0),
    .init(0.25, 0.15),
    .init(0.75, 0.85),
    .init(1, 1),
])
```

Curves operate on display-referred RGB in 0...1, after tone mapping. The master
curve runs first, followed by the individual channel curves. Interpolation is
shape-preserving cubic. Nonfinite points are ignored, values are clamped and
inputs within 0.0001 merge, keeping the last output. Missing endpoints are added; at most 32
points per curve are used.

The renderer bakes changed curves into a 32³ strip LUT, reuses that texture
between edits and releases it when the camera or effect is disabled. Neutral
curves bypass lookup entirely. Direct, FXAA and temporal presentation share the
existing LUT sampling path. Baking uses 8-bit channel samples.

## LUT textures

Choose an imported texture in **LUT Texture**. Supported layout is a horizontal
strip of N square tiles: width N×N, height N, with N between 2 and 256.
Typical sizes are 256×16 and 1024×32. Inside each tile, red increases left to
right and green increases from row 0 downward. Blue selects the tile from left
to right. Import the texture as **Data / Linear** so sRGB decoding does not alter
the lookup values. Square tiled LUTs and `.cube` files must first be converted
to this strip format.

```swift
environment.postProcess.colorGrading = ColorGrading3D(
    lut: try AssetsManager.loadSync(Texture2D.self, at: "@res://Looks/Warm.png"),
    lutIntensity: 0.7,
    correctionMode: .lut
)
```

Missing, unloaded and incorrectly sized LUTs leave the image unchanged. Older
scene payloads default to LUT mode, retaining their existing grading behavior.
