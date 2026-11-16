/// A deterministic scalar field over a supported coordinate type.
///
/// Infer `Point` from your sampling method, for example `Vector2` for terrain
/// heights or `Vector3` for volume density. Unsupported dimensions fail to compile.
/// Implementations must apply `frequency` to coordinates before evaluating the field.
public protocol Noise: Sendable {
    associatedtype Point: Sendable

    /// Samples the field after scaling its coordinates by `frequency`.
    func sample(at point: Point, frequency: Double) -> Double
}

public extension Noise {
    /// Samples the field with a unit coordinate-frequency multiplier.
    func sample(at point: Point) -> Double {
        sample(at: point, frequency: 1)
    }
}

/// Seeded 2D Perlin gradient noise with quintic interpolation, bounded to `-1...1`.
///
/// Uses hashed lattice gradients, not the canonical fixed permutation table.
/// Coordinates use `Vector2`'s Float precision; interpolation uses Double.
/// Nonfinite coordinates/frequency or coordinate-scaling overflow return NaN.
public struct PerlinNoise2D: Noise {
    public typealias Point = Vector2

    /// Seed selecting the deterministic gradient field.
    public let seed: UInt64

    /// Creates an immutable field. Sampling does not advance random state.
    public init(seed: UInt64 = 0) {
        self.seed = seed
    }

    public func sample(at point: Vector2, frequency: Double) -> Double {
        let x = Double(point.x) * frequency
        let y = Double(point.y) * frequency
        guard x.isFinite, y.isFinite else {
            return .nan
        }
        let ix = x.rounded(.down), iy = y.rounded(.down)
        let fx = x - ix, fy = y - iy
        let u = noiseFade(fx), v = noiseFade(fy)
        func gradient(_ cx: Double, _ cy: Double, _ dx: Double, _ dy: Double) -> Double {
            switch noiseHash(cx, cy, 0, seed: seed) & 7 {
            case 0: return dx + dy
            case 1: return -dx + dy
            case 2: return dx - dy
            case 3: return -dx - dy
            case 4: return dx
            case 5: return -dx
            case 6: return dy
            default: return -dy
            }
        }
        let lower = noiseLerp(gradient(ix, iy, fx, fy), gradient(ix + 1, iy, fx - 1, fy), u)
        let upper = noiseLerp(gradient(ix, iy + 1, fx, fy - 1), gradient(ix + 1, iy + 1, fx - 1, fy - 1), u)
        // Conservative scaling for the longest 2D gradients (sqrt(2)).
        return clamp(noiseLerp(lower, upper, v) * 0.7071067811865476, -1, 1)
    }
}

/// Seeded 3D Perlin gradient noise with quintic interpolation, bounded to `-1...1`.
///
/// Uses hashed lattice gradients and Vector3's Float coordinate precision.
/// Nonfinite coordinates/frequency or coordinate-scaling overflow return NaN.
public struct PerlinNoise3D: Noise {
    public typealias Point = Vector3

    /// Seed selecting the deterministic gradient field.
    public let seed: UInt64

    /// Creates an immutable field without shared random state.
    public init(seed: UInt64 = 0) {
        self.seed = seed
    }

    public func sample(at point: Vector3, frequency: Double) -> Double {
        let x = Double(point.x) * frequency
        let y = Double(point.y) * frequency
        let z = Double(point.z) * frequency
        guard x.isFinite, y.isFinite, z.isFinite else {
            return .nan
        }
        let ix = x.rounded(.down), iy = y.rounded(.down), iz = z.rounded(.down)
        let fx = x - ix, fy = y - iy, fz = z - iz
        let u = noiseFade(fx), v = noiseFade(fy), w = noiseFade(fz)
        func corner(_ dx: Double, _ dy: Double, _ dz: Double) -> Double {
            let hash = noiseHash(ix + dx, iy + dy, iz + dz, seed: seed) & 15
            let first = hash < 8 ? fx - dx : fy - dy
            let second = hash < 4 ? fy - dy : ((hash == 12 || hash == 14) ? fx - dx : fz - dz)
            return ((hash & 1) == 0 ? first : -first) + ((hash & 2) == 0 ? second : -second)
        }
        let x00 = noiseLerp(corner(0, 0, 0), corner(1, 0, 0), u)
        let x10 = noiseLerp(corner(0, 1, 0), corner(1, 1, 0), u)
        let x01 = noiseLerp(corner(0, 0, 1), corner(1, 0, 1), u)
        let x11 = noiseLerp(corner(0, 1, 1), corner(1, 1, 1), u)
        // Each gradient dot product lies in -2...2 within its cell.
        return clamp(noiseLerp(noiseLerp(x00, x10, v), noiseLerp(x01, x11, v), w) * 0.5, -1, 1)
    }
}

/// Normalized fractal Brownian motion over any `Noise` source.
///
/// Uses positive octave weights and preserves the source range, including custom
/// ranges outside -1...1. Invalid sample frequencies or overflow return NaN;
/// invalid source samples propagate. Sampling is synchronous and allocation-free
/// apart from work performed by the source itself.
public struct FractalNoise<Source: Noise>: Noise {
    public typealias Point = Source.Point

    /// The field sampled by each octave.
    public let source: Source
    /// Number of octaves, clamped to 1...32.
    public let octaves: Int
    /// Base frequency. Nonfinite or non-positive settings become 1.
    public let frequency: Double
    /// Frequency multiplier per octave. Nonfinite or non-positive settings become 2.
    public let lacunarity: Double
    /// Amplitude multiplier per octave, clamped to 0...1. Nonfinite settings become 0.5.
    public let persistence: Double

    /// Creates a normalized FBM field using the documented setting normalization.
    public init(source: Source, octaves: Int = 5, frequency: Double = 1, lacunarity: Double = 2, persistence: Double = 0.5) {
        self.source = source
        self.octaves = max(1, min(32, octaves))
        self.frequency = frequency.isFinite && frequency > 0 ? frequency : 1
        self.lacunarity = lacunarity.isFinite && lacunarity > 0 ? lacunarity : 2
        self.persistence = persistence.isFinite ? clamp(persistence, 0, 1) : 0.5
    }

    public func sample(at point: Point, frequency: Double) -> Double {
        guard frequency.isFinite else {
            return .nan
        }
        var normalized = 0.0
        var amplitude = 1.0
        var totalAmplitude = 0.0
        var octaveFrequency = frequency * self.frequency
        for _ in 0..<octaves {
            guard amplitude > 0 else { break }
            guard octaveFrequency.isFinite else {
                return .nan
            }
            let sample = source.sample(at: point, frequency: octaveFrequency)
            guard sample.isFinite else {
                return sample
            }
            let nextTotal = totalAmplitude + amplitude
            let currentWeight = amplitude / nextTotal
            if normalized.sign == sample.sign {
                // Same-sign interpolation avoids overflowing a rounded weight sum > 1.
                normalized += (sample - normalized) * currentWeight
            } else {
                // Opposite-sign scaled terms cannot overflow when added.
                normalized = normalized * (1 - currentWeight) + sample * currentWeight
            }
            totalAmplitude = nextTotal
            amplitude *= persistence
            octaveFrequency *= lacunarity
        }
        return normalized
    }
}

private func noiseHash(_ x: Double, _ y: Double, _ z: Double, seed: UInt64) -> UInt64 {
    // A lattice vertex must have identical gradients on both sides of zero.
    let xBits = x == 0 ? 0 : x.bitPattern
    let yBits = y == 0 ? 0 : y.bitPattern
    let zBits = z == 0 ? 0 : z.bitPattern
    var hash = xBits &* 0x9E3779B97F4A7C15 ^ yBits &* 0xD1B54A32D192ED03 ^ zBits &* 0x94D049BB133111EB ^ seed
    hash = (hash ^ (hash >> 30)) &* 0xBF58476D1CE4E5B9
    hash = (hash ^ (hash >> 27)) &* 0x94D049BB133111EB
    return hash ^ (hash >> 31)
}

private func noiseFade(_ value: Double) -> Double {
    value * value * value * (value * (value * 6 - 15) + 10)
}

private func noiseLerp(_ lower: Double, _ upper: Double, _ weight: Double) -> Double {
    lower + (upper - lower) * weight
}
