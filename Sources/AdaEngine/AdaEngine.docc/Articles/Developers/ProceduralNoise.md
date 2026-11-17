# Procedural Noise

Use a noise generator as a deterministic scalar field for terrain heights,
procedural placement, or volume density. Import `Math` directly, or use its
re-export from `AdaEngine`. No GPU or editor state is needed.

## Sample seeded Perlin noise

`PerlinNoise2D` and `PerlinNoise3D` return values within `-1...1` for finite
coordinates and frequency. Fixed seeds and coordinates produce repeatable samples;
sampling does not advance a random generator. These are hashed-gradient Perlin
variants with quintic interpolation, not bit-compatible implementations of the
canonical permutation-table algorithm. 2D noise is its own field, not a 3D slice.

```swift
import Math

let perlin = PerlinNoise2D(seed: 1234)
let heightVariation = perlin.sample(at: Vector2(12.5, 8.25))
let volume = PerlinNoise3D(seed: 1234)
let density = volume.sample(at: Vector3(12.5, 8.25, -2))
```

## Layer terrain detail with FBM

`FractalNoise` combines samples at increasing frequencies and decreasing
amplitudes. This example computes a height; it does not modify a terrain entity.

```swift
let terrain = FractalNoise(
    source: PerlinNoise2D(seed: 1234),
    octaves: 5,
    frequency: 0.02,
    lacunarity: 2,
    persistence: 0.5
)
let worldX: Float = 32
let worldZ: Float = -16
let height = terrain.sample(at: Vector2(worldX, worldZ)) * 20
```

- `octaves`: number of layers, clamped to `1...32`.
- `frequency`: base coordinate scale. Nonfinite/non-positive settings become `1`.
- `lacunarity`: frequency multiplier between octaves. Nonfinite/non-positive settings become `2`.
- `persistence`: amplitude multiplier between octaves, clamped to `0...1`.
  Nonfinite settings become `0.5`. Zero uses only the first octave.

Output is divided by the sum of active octave amplitudes. Sources bounded to
`-1...1` stay within that range; custom source ranges are not clipped.
The optional `sample(at:frequency:)` argument multiplies the base frequency,
including when fractal fields are nested. Zero or negative call frequencies are
valid coordinate transforms; the initializer's positive settings have the
normalization rules above.

## Implement a custom generator

`Noise` has an associated `Point` type inferred from the sampling method. A 2D
implementation cannot accidentally be called with a 3D point. A custom field only
needs to be `Sendable` and implement one method:

```swift
struct RidgeNoise: Noise {
    func sample(at point: Vector2, frequency: Double) -> Double {
        let x = Double(point.x) * frequency
        return 1 - abs(Math.sin(x))
    }
}

let ridges = FractalNoise(source: RidgeNoise(), frequency: 0.1)
let ridgeHeight = ridges.sample(at: Vector2(10, 20))
```

Use the same type for a custom terrain field that composes several generators.
An immutable struct is usually sufficient; no base class or shared mutable seed
is necessary. `Noise.sample(at:)` also works in generic code, using unit frequency.

## Limits and invalid input

Vector2/Vector3 store Float coordinates. Double interpolation cannot recover
precision already lost in a large world position; use local coordinates before
conversion for fine detail far from the origin. No serialization, shader noise,
terrain wiring, or cross-library sample compatibility is provided here.

Perlin sampling returns NaN for nonfinite inputs or coordinate-scaling overflow.
FBM returns NaN for nonfinite call frequency or active-octave frequency overflow,
and propagates invalid samples from its source. Custom sources define their own
coordinate validation. Check `isFinite` before storing a computed terrain height;
invalid sample input is not silently converted to a valid height.

See <doc:Terrain> for the separate terrain creation and editing API.
