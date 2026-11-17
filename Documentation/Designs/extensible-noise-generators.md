# Extensible Noise Generators

Status: **Accepted**

Approval: explicit user message “approve!” in session-99516dcb-c664-4d3a-8254-623324cb00e7.
Implementation details and dimensional alternative selection: [implementation plan](../Plans/extensible-noise-generators.md).

## Goal

Provide a reusable public API for procedural noise so engine users can implement custom generators by conforming to a shared protocol. Include deterministic seeded Perlin noise and a fractal/FBM composition suitable for terrain height sampling.

## Context

`AdaScene/3D/Terrain/TerrainMaterialResolver.swift` contains private seeded 2D value noise used to vary terrain material weights. No shared public noise abstraction was found in the source search. That implementation is not itself a terrain height generator, and this proposal does not silently replace or wire it into terrain.

## Scope and Ownership

- Add the public API in the engine's existing `Math` module, subject to confirmation of the package's target ownership during implementation. Noise sampling is general-purpose math and should not depend on AdaScene.
- Define a `Noise` protocol with distinct 2D and 3D sampling requirements and defaults that let a custom 2D-only implementation conform without inventing 3D behavior. Calling an unsupported dimensional default must fail explicitly rather than fabricate a sample.
- Provide deterministic seeded `PerlinNoise` implementations for 2D and 3D, with documented output range and repeatability.
- Provide an `FractalNoise`/FBM composition over a `Noise` source with configurable octave count, lacunarity, persistence, and initial frequency. Define bounded parameter handling and normalized output behavior.
- Keep sampling value-based and suitable for repeated terrain queries; do not add global mutable seed state or external dependencies.
- Do not change terrain generation or terrain material blending in this delivery. Terrain integration can be a later feature using the new API.

## API Shape (Illustrative)

```swift
public protocol Noise: Sendable {
    func sample(x: Double, y: Double) -> Double
    func sample(x: Double, y: Double, z: Double) -> Double
}

public struct PerlinNoise: Noise { /* immutable seed/configuration */ }
public struct FractalNoise<Source: Noise>: Noise { /* source and FBM settings */ }
```

Exact naming, coordinate scalar type, default-method behavior, and availability of a 2D/3D capability refinement will be settled against AdaEngine's existing `Math` conventions before implementation. The illustrative API is not a compatibility promise.

## Behavior and Constraints

- Same seed and coordinates produce the same result across repeated calls.
- Sampling is continuous across cell boundaries; Perlin's gradient interpolation avoids discontinuous cell noise.
- 2D and 3D APIs have explicit semantics; 2D sampling must not be implemented as an undocumented slice through 3D.
- Invalid fractal settings (such as non-positive octave count or non-finite frequency parameters) are rejected or normalized according to a documented, tested policy; no silent NaN propagation.
- The API remains usable from Swift 6.2 strict-concurrency contexts and its public value types are `Sendable`.

## Alternatives

1. Protocol with both dimensions and explicit defaults: simple call sites, but unsupported dimensional calls require an explicit failure behavior.
2. Separate `Noise2D` and `Noise3D` protocols with a common marker/base protocol: stronger compile-time capability guarantees, but more types and generic constraints.
3. Dimension-generic coordinates: compact conceptual API, but less ergonomic and likely less aligned with existing `Vector2`/`Vector3` APIs.

The implementation should prefer the smallest design that retains honest dimensional capabilities; no artificial base class is proposed because Swift protocols provide the desired conformance model.

## User Documentation

Add a discoverable DocC article in the existing engine user guide/catalog (likely `Sources/AdaEngine/AdaEngine.docc/Articles/Developers/ProceduralNoise.md`, after confirming catalog structure). Explain custom conformance, seeded Perlin sampling, FBM composition for terrain heights, parameter meanings, deterministic behavior, and dimensional limitations. Add it to the relevant DocC navigation and include a compiling example.

## Acceptance Criteria

- A user can define a custom 2D noise type by conforming to the public protocol without implementing fake 3D sampling.
- Built-in seeded Perlin sampling exists in 2D and 3D and is deterministic for fixed input.
- Fractal/FBM composition exposes octave, persistence, lacunarity, and base frequency controls and has tested output bounds/edge behavior.
- Focused Swift Testing tests cover determinism, representative values, continuity at lattice boundaries, 2D/3D behavior, custom conformance, and FBM settings.
- Public symbols have DocC comments and a discoverable user-facing article with a verified example.
- No terrain integration or changes to existing terrain material behavior are included.

## Tests / Verification

- Run focused Math/noise tests, then the owning Math target tests.
- Build the AdaEngine package using the repository's prescribed isolated scratch path if the shared Swift cache reports a toolchain mismatch.
- Build/validate the DocC example and navigation using the established documentation workflow.
- Run `python script/check_contribution.py` workflow stages and obtain independent review after implementation; do not treat this proposal as implementation approval.

## Open Design Choice

The exact unsupported-dimension behavior should be resolved before coding: prefer capability-separated protocols (e.g. `Noise2D`/`Noise3D`) if the repository favors compile-time guarantees; otherwise provide a clear throwing/default failure contract. The user approves the desired behavior and design, not merely this document's existence.
