# Extensible Noise Implementation Plan

Approved scope: `../Designs/extensible-noise-generators.md`, approved by the user with “approve!” in the project conversation.

## Recovery and ownership

The initial attempt created an incomplete implementation before recording a plan or behavioral Red. Preserve its workflow record; initialize `extensible-noise-recovery` with this plan rather than fabricating prior evidence. Original tests were not test-first. A fresh behavioral regression demonstrates the existing FBM frequency bug before its correction.

Owned files: the design, this plan, `Sources/Math/Noise.swift`, `Tests/MathTests/NoiseTests.swift`, the `ProceduralNoise.md` DocC article, and the engine catalog navigation. No terrain consumer changes, dependencies, manifests, or UI changes.

## API decisions

Use the design's dimension-generic coordinate alternative: `Noise.Point: Sendable` with `sample(at:frequency:) -> Double`. PerlinNoise2D uses existing Float-based Vector2, PerlinNoise3D uses Vector3; arithmetic is Double after reading coordinates. A custom implementation declares its supported coordinate by its method signature. Unsupported dimensions are compile-time errors, never fallback samples or traps. A protocol extension supplies unit-frequency sampling in generic code.

FBM multiplies call frequency and base frequency exactly once, preserves source output range by normalized positive weights (does not clip arbitrary custom sources), and stops when amplitude reaches zero. Settings normalize octaves to 1...32, invalid positive frequency/lacunarity to 1/2, and persistence to 0...1 (nonfinite to 0.5). Sampling returns NaN for nonfinite coordinates/frequencies or frequency overflow; this is explicit invalid-input behavior, documented and tested. Perlin is a seeded hashed-gradient variant, not bit-compatible with a canonical permutation table. Canonicalize signed zero lattice coordinates so adjacent negative/positive cells share gradients.

## Implementation and tests

1. Resolve missing floor symbol without adding platform imports: use Double.rounded(.down).
2. Record failing FBM base/call frequency test, fix it, record Green with unchanged tests.
3. Add boundary/invalid-input, octave weighting, persistence-zero, custom-source range, 3D seed and continuity regressions. Confirm Red before corresponding fixes and run owning MathTests.
4. Update the guide with self-contained, compiled examples, dimensional limitations, coordinate precision and no automatic terrain integration. Maintain DocC Topics navigation.
5. Run contribution validation, build package, check DocC, and obtain independent review of final code, examples and evidence. Missing prerequisites remain blockers.

## Verification

Reuse `/tmp/adaengine-noise-build` for SwiftPM builds/tests with Swift 6.3.2, language mode 6.2. Run focused NoiseTests followed by MathTests; run `swift build` on the package. Use task-owned output for documentation, leaving generated `docs/` unchanged. Full contributor profile, analyzers, platform recipes and review remain required for Done; report unavailable checks rather than weakening gates.
