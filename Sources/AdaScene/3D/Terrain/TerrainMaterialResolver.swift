import AdaAssets
import AdaGeometry
import Foundation
import Math

/// Immutable per-generation lookup. Evaluating a sample uses fixed stack storage, not per-sample arrays or dictionaries.
struct TerrainMaterialResolver: Sendable {
    private struct Rule: Sendable {
        let slot: Int
        let settings: TerrainMaterialRule
    }

    private let layerIDs: [UInt16]
    private let rules: [Rule]
    private let fallbackID: UInt16
    let needsCurvature: Bool
    /// Canonical geometry/normal/mask work plus each bounded rule evaluation.
    var evaluationWorkCost: Int { 32 + rules.count + (needsCurvature ? 16 : 0) }

    init(_ palette: TerrainMaterialPalette) throws {
        try palette.validate()
        layerIDs = palette.layers.map(\.id).sorted()
        let slots = Dictionary(uniqueKeysWithValues: layerIDs.enumerated().map { ($0.element, $0.offset) })
        rules = palette.rules.filter(\.enabled).compactMap { rule in slots[rule.layerID].map { Rule(slot: $0, settings: rule) } }
        fallbackID = palette.fallbackLayerID
        needsCurvature = rules.contains { $0.settings.curvature != nil }
    }

    func resolve(position: Vector3, normal: Vector3, curvature: Double = 0, mask: (UInt16) -> Float = { _ in 0 }) -> (ids: Vector4, weights: Vector4) {
        normalized(automaticWeights(position: position, normal: normal, curvature: curvature, mask: mask))
    }

    func resolveMesh(
        position: Vector3,
        normal: Vector3,
        contact: MeshTerrainLayerContact?,
        sourceLayer: UInt16?,
        paint: MeshTerrainCompiledPaint.Sample?
    ) throws -> (ids: Vector4, weights: Vector4) {
        var values = SIMD32<Float>(repeating: 0)
        if let sourceLayer, let slot = layerIDs.firstIndex(of: sourceLayer) {
            values[slot] = 1
        } else {
            values = automaticWeights(position: position, normal: normal, curvature: 0, mask: { _ in 0 })
            let sum = values.sum()
            if sum > 0 { values /= sum }
            else if let slot = layerIDs.firstIndex(of: fallbackID) { values[slot] = 1 }
            if let contact, contact.automatic < 1 { values = values * contact.automatic + contact.weights }
        }
        if let paint {
            let coverage = paint.layers.reduce(Float(0)) { $0 + $1.weight }
            values *= max(0, 1 - coverage)
            for layer in paint.layers {
                guard let slot = layerIDs.firstIndex(of: layer.id) else {
                    throw TerrainSourceError.resourceLoadingFailed("Painted terrain layer \(layer.id) is missing from the palette")
                }
                values[slot] += layer.weight
            }
        }
        return normalized(values)
    }

    private func automaticWeights(position: Vector3, normal: Vector3, curvature: Double, mask: (UInt16) -> Float) -> SIMD32<Float> {
        var accumulated = SIMD32<Float>(repeating: 0)
        let slope = Foundation.acos(max(-1, min(1, Double(normal.y)))) * 180 / Double.pi
        for rule in rules {
            let value = rule.settings
            var weight = value.weight * range(value.height, Double(position.y)) * range(value.slope, slope) * range(value.curvature, curvature)
            if let id = value.maskID { weight *= max(0, min(1, mask(id))) }
            if value.noiseStrength > 0 {
                weight *= 1 - value.noiseStrength + value.noiseStrength * noise(position, frequency: value.noiseFrequency, seed: value.seed)
            }
            if weight.isFinite, weight > 0 { accumulated[rule.slot] += weight }
        }
        return accumulated
    }

    func resolve(
        position: Vector3,
        normal: Vector3,
        curvature: Double = 0,
        paint: TerrainRegionSurfaceSample?,
        mask: (UInt16) -> Float = { _ in 0 }
    ) throws -> (ids: Vector4, weights: Vector4) {
        let automatic = resolve(position: position, normal: normal, curvature: curvature, mask: mask)
        guard let paint, paint.overrideStrength > 0 else {
            return automatic
        }
        var accumulated = SIMD32<Float>(repeating: 0)
        for channel in 0..<4 where automatic.weights[channel] > 0 {
            if let slot = layerIDs.firstIndex(of: UInt16(automatic.ids[channel])) {
                accumulated[slot] += automatic.weights[channel] * (1 - paint.overrideStrength)
            }
        }
        for channel in 0..<4 where paint.weights[channel] > 0 {
            let id = paint.layerIDs[channel]
            guard let slot = layerIDs.firstIndex(of: id) else {
                throw TerrainSourceError.resourceLoadingFailed("Painted terrain layer \(id) is missing from the palette")
            }
            accumulated[slot] += paint.weights[channel] * paint.overrideStrength
        }
        return normalized(accumulated)
    }

    private func normalized(_ values: SIMD32<Float>) -> (ids: Vector4, weights: Vector4) {
        var accumulated = values
        var ids = Vector4.zero
        var weights = Vector4.zero
        var sum: Float = 0
        for output in 0..<4 {
            var best: Int?
            var largest: Float = 0
            // IDs are sorted, so equal weights always favor the same stable ID.
            for slot in layerIDs.indices where accumulated[slot] > largest {
                best = slot
                largest = accumulated[slot]
            }
            guard let best else { break }
            ids[output] = Float(layerIDs[best])
            weights[output] = largest
            sum += largest
            accumulated[best] = 0
        }
        guard sum > 0 else {
            return (Vector4(Float(fallbackID), 0, 0, 0), Vector4(1, 0, 0, 0))
        }
        return (ids, weights / sum)
    }

    private func range(_ range: TerrainMaterialRange?, _ value: Double) -> Float {
        guard let range else {
            return 1
        }
        let minimum = Double(range.minimum), maximum = Double(range.maximum), transition = Double(range.transition)
        if value >= minimum, value <= maximum {
            return 1
        }
        guard transition > 0 else {
            return 0
        }
        let distance = value < minimum ? minimum - value : value - maximum
        let factor = max(0, min(1, 1 - distance / transition))
        return Float(factor * factor * (3 - 2 * factor))
    }

    private func noise(_ point: Vector3, frequency: Float, seed: UInt64) -> Float {
        let x = Double(point.x) * Double(frequency), z = Double(point.z) * Double(frequency)
        let ix = floor(x), iz = floor(z)
        let fx = x - ix, fz = z - iz
        let u = fx * fx * (3 - 2 * fx), v = fz * fz * (3 - 2 * fz)
        func value(_ x: Double, _ z: Double) -> Double {
            var bits = x.bitPattern &* 0x9E37_79B9_7F4A_7C15 ^ z.bitPattern &* 0xD1B5_4A32_D192_ED03 ^ seed
            bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
            bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
            bits ^= bits >> 31
            return Double(bits >> 40) / 16_777_215
        }
        let a = value(ix, iz), b = value(ix + 1, iz), c = value(ix, iz + 1), d = value(ix + 1, iz + 1)
        return Float((a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v)
    }
}
