//
//  MorphTargetSet.swift
//  AdaEngine
//

import Math

/// The morph targets of one mesh part, packed for the GPU.
///
/// Every target stores, for every vertex, a position delta and optionally a normal delta and a tangent delta, in one
/// half-float texture. The vertex shader reads the deltas of the few active targets with `texelFetch`, so any number of
/// targets cost memory but only the active ones cost time. Texel `i` is `(target * vertexCount + vertex) * attributes +
/// attribute`, laid out row by row in a texture ``textureWidth`` texels wide; the attributes are position, then normal and
/// tangent when any target has them.
public struct MorphTargetSet: Sendable {
    /// Width of the delta texture in texels.
    public static let textureWidth = 2048
    /// Tallest delta texture; with ``textureWidth`` this bounds `targets * vertices * attributes` to about 16.7 million texels.
    public static let maximumTextureRows = 8192
    /// Most targets a draw applies at once; the heaviest weights win.
    public static let maximumActiveTargets = 8

    public let targetCount: Int
    public let vertexCount: Int
    /// Texels per vertex and target: 1 for positions only, up to 3 with normals and tangents.
    public let attributesPerVertex: Int
    public let hasNormals: Bool
    public let hasTangents: Bool
    public let targetNames: [String]
    /// Per target, the longest position delta; an upper bound of how far the target can move any vertex.
    public let maximumDisplacements: [Float]
    public let deltaTexture: Texture2D
    private let positionDeltas: [[UInt16]]

    /// Flags for the shader: bit 0 normals present, bit 1 tangents present.
    public var attributeFlags: Float { Float((hasNormals ? 1 : 0) | (hasTangents ? 2 : 0)) }

    /// Packs per-target deltas. An empty array for a target and attribute means no displacement. Returns `nil` when there are
    /// no targets or vertices, an array has the wrong length, a value is not finite, or the deltas would not fit the
    /// texture.
    public init?(
        positionDeltas: [[Vector3]],
        normalDeltas: [[Vector3]],
        tangentDeltas: [[Vector3]],
        vertexCount: Int,
        targetNames: [String] = []
    ) {
        let targetCount = positionDeltas.count
        guard targetCount > 0, vertexCount > 0, normalDeltas.count == targetCount, tangentDeltas.count == targetCount else {
            return nil
        }
        func valid(_ deltas: [[Vector3]]) -> Bool {
            deltas.allSatisfy { $0.isEmpty || ($0.count == vertexCount && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) }
        }
        guard valid(positionDeltas), valid(normalDeltas), valid(tangentDeltas) else {
            return nil
        }
        let hasNormals = normalDeltas.contains { !$0.isEmpty }
        let hasTangents = tangentDeltas.contains { !$0.isEmpty }
        let attributes = 1 + (hasNormals ? 1 : 0) + (hasTangents ? 1 : 0)
        let (texels, overflow) = targetCount.multipliedReportingOverflow(by: vertexCount)
        let (total, overflowTotal) = texels.multipliedReportingOverflow(by: attributes)
        let width = Self.textureWidth
        guard !overflow, !overflowTotal, total <= width * Self.maximumTextureRows else {
            return nil
        }
        let rows = (total + width - 1) / width
        var halves = [UInt16](repeating: 0, count: width * rows * 4)
        var displacements = [Float](repeating: 0, count: targetCount)
        func write(_ deltas: [Vector3], target: Int, attribute: Int) {
            guard !deltas.isEmpty else { return }
            for vertex in 0..<vertexCount {
                let texel = (target * vertexCount + vertex) * attributes + attribute
                let offset = texel * 4
                halves[offset] = Self.halfBits(deltas[vertex].x)
                halves[offset + 1] = Self.halfBits(deltas[vertex].y)
                halves[offset + 2] = Self.halfBits(deltas[vertex].z)
            }
        }
        for target in 0..<targetCount {
            write(positionDeltas[target], target: target, attribute: 0)
            if hasNormals { write(normalDeltas[target], target: target, attribute: 1) }
            if hasTangents { write(tangentDeltas[target], target: target, attribute: hasNormals ? 2 : 1) }
            displacements[target] = positionDeltas[target].reduce(0) { max($0, $1.length) }
        }
        let texture = Texture2D(descriptor: TextureDescriptor(
            width: width,
            height: rows,
            pixelFormat: .rgba_16f,
            textureUsage: [.read],
            textureType: .texture2D,
            debugLabel: "Morph Target Deltas",
            samplerDescription: SamplerDescriptor(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped)
        ))
        unsafe halves.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                texture.replaceRegion(RectInt(x: 0, y: 0, width: width, height: rows), withBytes: base, bytesPerRow: width * 8)
            }
        }
        self.targetCount = targetCount
        self.vertexCount = vertexCount
        self.attributesPerVertex = attributes
        self.hasNormals = hasNormals
        self.hasTangents = hasTangents
        self.targetNames = targetNames
        self.maximumDisplacements = displacements
        self.deltaTexture = texture
        self.positionDeltas = positionDeltas.enumerated().map { target, deltas in
            guard !deltas.isEmpty else {
                return []
            }
            var packed: [UInt16] = []
            packed.reserveCapacity(vertexCount * 3)
            for vertex in 0..<vertexCount {
                let start = (target * vertexCount + vertex) * attributes * 4
                packed.append(contentsOf: halves[start..<(start + 3)])
            }
            return packed
        }
    }

    /// Position data as seen by the shader after half-float conversion.
    package func renderPositionDelta(target: Int, vertex: Int) -> Vector3 {
        guard positionDeltas.indices.contains(target), (0..<vertexCount).contains(vertex) else {
            return .zero
        }
        let deltas = positionDeltas[target]
        guard !deltas.isEmpty else {
            return .zero
        }
        let offset = vertex * 3
        return Vector3(
            Self.float(fromHalfBits: deltas[offset]),
            Self.float(fromHalfBits: deltas[offset + 1]),
            Self.float(fromHalfBits: deltas[offset + 2])
        )
    }

    /// IEEE half-precision bits of a finite float, rounding to nearest and saturating at the largest finite half.
    /// Written out because `Float16` does not exist on every platform the engine builds for.
    @_spi(Internal)
    public static func halfBits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        let mantissa = bits & 0x7F_FFFF
        if exponent >= 31 {
            return sign | 0x7BFF
        }
        if exponent <= 0 {
            guard exponent >= -10 else { return sign }
            let significand = mantissa | 0x80_0000
            let shift = UInt32(14 - exponent)
            var half = UInt16(significand >> shift)
            if (significand >> (shift - 1)) & 1 == 1 { half &+= 1 }
            return sign | half
        }
        var half = UInt16(exponent << 10) | UInt16(mantissa >> 13)
        if mantissa & 0x1000 != 0 { half &+= 1 }
        return sign | half
    }

    /// The value of half-precision bits as a float.
    @_spi(Internal)
    public static func float(fromHalfBits half: UInt16) -> Float {
        let sign: Float = half & 0x8000 != 0 ? -1 : 1
        let exponent = Int((half >> 10) & 0x1F)
        let mantissa = Float(half & 0x3FF)
        if exponent == 0 { return sign * mantissa * Float(sign: .plus, exponent: -24, significand: 1) }
        if exponent == 31 { return sign * .infinity }
        return sign * (1 + mantissa / 1024) * Float(sign: .plus, exponent: exponent - 15, significand: 1)
    }

    /// The most the active weights can move any vertex, for growing culling bounds. Weights past the active limit are ignored
    /// the way the shader ignores them.
    public func maximumDisplacement(for weights: [Float]) -> Float {
        var total: Float = 0
        for (index, weight) in Self.activeTargets(weights: weights) {
            total += abs(weight) * maximumDisplacements[index]
        }
        return total
    }

    /// The up to ``maximumActiveTargets`` targets with the largest weights, as (target index, weight). Targets whose weight is
    /// zero or not finite are skipped. Ties keep the lower index first.
    public static func activeTargets(weights: [Float], limit: Int = maximumActiveTargets) -> [(index: Int, weight: Float)] {
        var candidates: [(index: Int, weight: Float)] = []
        for (index, weight) in weights.enumerated() where weight.isFinite && weight != 0 {
            candidates.append((index, weight))
        }
        candidates.sort { abs($0.weight) == abs($1.weight) ? $0.index < $1.index : abs($0.weight) > abs($1.weight) }
        return Array(candidates.prefix(limit))
    }
}

extension Mesh {
    /// Whether any part of this mesh has morph targets.
    public var hasMorphTargets: Bool {
        models.contains { model in model.parts.contains { $0.morphTargets != nil } }
    }

    /// The target names of the first morphed part, empty when there are none.
    public var morphTargetNames: [String] {
        for model in models {
            for part in model.parts {
                if let set = part.morphTargets { return set.targetNames }
            }
        }
        return []
    }

    /// The number of morph targets of the first morphed part, zero when there are none.
    public var morphTargetCount: Int {
        for model in models {
            for part in model.parts {
                if let set = part.morphTargets { return set.targetCount }
            }
        }
        return 0
    }
}
