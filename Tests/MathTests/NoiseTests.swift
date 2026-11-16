import Math
import Testing

@Suite("Noise generators")
struct NoiseTests {
    private struct Constant2D: Noise {
        func sample(at point: Vector2, frequency: Double) -> Double { 0.25 }
    }

    @Test func perlinIsDeterministicAndSeeded() {
        let point = Vector2(1.25, -3.75)
        let first = PerlinNoise2D(seed: 42).sample(at: point)
        #expect(first == PerlinNoise2D(seed: 42).sample(at: point))
        #expect(first != PerlinNoise2D(seed: 43).sample(at: point))
    }

    @Test func perlinIsContinuousAcrossCellBoundary() {
        let noise = PerlinNoise2D(seed: 7)
        let left = noise.sample(at: Vector2(0.9999, 0.37))
        let right = noise.sample(at: Vector2(1.0001, 0.37))
        #expect(abs(left - right) < 0.001)
    }

    @Test func threeDimensionalPerlinIsDeterministic() {
        let point = Vector3(0.25, -1.5, 3.75)
        let first = PerlinNoise3D(seed: 4).sample(at: point)
        let recreated = PerlinNoise3D(seed: 4)
        #expect(first == recreated.sample(at: point))
    }

    private struct Frequency2D: Noise {
        func sample(at point: Vector2, frequency: Double) -> Double { frequency / 100 }
    }

    @Test func fbmUsesBaseAndCallFrequencyExactlyOnce() {
        let noise = FractalNoise(source: Frequency2D(), octaves: 1, frequency: 2)
        #expect(noise.sample(at: .zero) == 0.02)
        #expect(noise.sample(at: .zero, frequency: 3) == 0.06)
    }

    @Test func customNoiseCanBeComposedAsFBM() {
        let noise = FractalNoise(source: Constant2D(), octaves: 4, persistence: 0.5)
        #expect(noise.sample(at: Vector2(12, -9)) == 0.25)
        #expect(noise.sample(at: Vector2.zero) >= -1 && noise.sample(at: Vector2.zero) <= 1)
    }
    private struct LargeConstant: Noise {
        func sample(at point: Vector2, frequency: Double) -> Double { 2 }
    }

    @Test func fbmPreservesCustomSourceRange() {
        #expect(FractalNoise(source: LargeConstant()).sample(at: .zero) == 2)
    }

    private struct UnitFrequencyOnly: Noise {
        func sample(at point: Vector2, frequency: Double) -> Double {
            frequency == 1 ? 0.25 : .nan
        }
    }

    @Test func zeroPersistenceDoesNotEvaluateZeroWeightOctaves() {
        let noise = FractalNoise(source: UnitFrequencyOnly(), persistence: 0)
        #expect(noise.sample(at: .zero) == 0.25)
    }

    @Test func signedZeroHasIdenticalLatticeGradients() {
        let noise = PerlinNoise2D(seed: 12)
        #expect(noise.sample(at: Vector2(-0.0, 0.37)) == noise.sample(at: Vector2(0, 0.37)))
    }

    @Test func fbmUsesNormalizedOctaveWeights() {
        let noise = FractalNoise(source: Frequency2D(), octaves: 3, frequency: 1, lacunarity: 2, persistence: 0.5)
        #expect(abs(noise.sample(at: .zero) - 0.03 / 1.75) < 1e-12)
    }

    @Test func settingsAreNormalized() {
        let noise = FractalNoise(source: Constant2D(), octaves: -1, frequency: .nan, lacunarity: .infinity, persistence: 9)
        #expect(noise.octaves == 1)
        #expect(noise.frequency == 1)
        #expect(noise.lacunarity == 2)
        #expect(noise.persistence == 1)
        #expect(FractalNoise(source: Constant2D(), octaves: 99, persistence: .nan).octaves == 32)
        #expect(FractalNoise(source: Constant2D(), persistence: .nan).persistence == 0.5)
        #expect(FractalNoise(source: Constant2D(), persistence: -1).persistence == 0)
    }

    @Test func perlinBoundsLatticeZerosAndThreeDimensionalVariation() {
        let two = PerlinNoise2D(seed: 42)
        let three = PerlinNoise3D(seed: 42)
        for index in -16...16 {
            #expect(two.sample(at: Vector2(Float(index), 2)) == 0)
            #expect(three.sample(at: Vector3(Float(index), 2, -3)) == 0)
            let position = Float(index) * 0.137
            let a = two.sample(at: Vector2(position, 0.37))
            let b = three.sample(at: Vector3(position, 0.37, 0.71))
            #expect(a.isFinite && abs(a) <= 1)
            #expect(b.isFinite && abs(b) <= 1)
        }
        let point = Vector3(0.37, 0.21, 0.73)
        #expect(three.sample(at: point) != three.sample(at: Vector3(point.x, point.y, 1.73)))
        #expect(three.sample(at: point) != PerlinNoise3D(seed: 43).sample(at: point))
        #expect(abs(three.sample(at: Vector3(0.9999, 0.37, 0.71)) - three.sample(at: Vector3(1.0001, 0.37, 0.71))) < 0.001)
    }

    @Test func samplingRejectsNonfiniteFrequencyEvenForCustomSource() {
        #expect(FractalNoise(source: Constant2D()).sample(at: .zero, frequency: .infinity).isNaN)
        #expect(PerlinNoise2D().sample(at: Vector2(.nan, 0)).isNaN)
        #expect(PerlinNoise3D().sample(at: Vector3(0, .infinity, 0)).isNaN)
    }
    private struct ExtremeConstant: Noise {
        let value: Double
        func sample(at point: Vector2, frequency: Double) -> Double { value }
    }

    @Test func fbmPreservesExtremeFiniteSourceRange() {
        for value in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            for persistence in [0.1, 1.0] {
                let field = FractalNoise(source: ExtremeConstant(value: value), octaves: 32, persistence: persistence)
                let result = field.sample(at: .zero)
                #expect(result.isFinite)
                #expect(abs((result / value) - 1) < 1e-14)
            }
        }
    }

    @Test func nestedFbmPreservesCallFrequency() {
        let inner = FractalNoise(source: Frequency2D(), octaves: 1, frequency: 2)
        let outer = FractalNoise(source: inner, octaves: 1, frequency: 3)
        #expect(outer.sample(at: .zero, frequency: 2) == 0.12)
    }
}
