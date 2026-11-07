import AdaAssets
import Math

/// Bounded worker evaluation over canonical surface samples; the existing edit kernel owns final admission.
struct TerrainSurfaceBrushKernel {
    let source: TerrainHeightStorage
    let stroke: TerrainSurfaceBrushStroke
    let plan: TerrainHeightBrushPlan

    func evaluate() throws -> (surface: [TerrainSurfaceUpdate], masks: [TerrainRuleMaskUpdate], maskEvaluations: Int) {
        let settings = stroke.settings, mask = try stroke.samplingStroke().settings
        let original = source.surfaceSnapshot()
        // The planner charges active dabs. Filter once, so inactive pointer travel
        // adds neither mask work nor a repeated inactive scan for every surface sample.
        let dabs = plan.dabs.filter { $0.pressure > 0 }
        let points = plan.footprint.sorted { $0.z == $1.z ? $0.x < $1.x : $0.z < $1.z }
        var surface: [TerrainSurfaceUpdate] = [], masks: [TerrainRuleMaskUpdate] = []
        var visits = 0
        for point in points {
            try Task.checkCancellation()
            guard let height = source.height(atSample: point) else { continue }
            if let range = settings.heightRange, !range.contains(height) { continue }
            if let range = settings.slopeRange {
                guard let normal = source.normalForBrush(at: point) else { continue }
                let nx = Double(normal.x), nz = Double(normal.z)
                let slope = Float(Math.atan2((nx * nx + nz * nz).squareRoot(), Double(normal.y)) * 180 / Double.pi)
                if !range.contains(slope) { continue }
            }
            let previous = original.sample(at: point)?.paint
            var value = TerrainSurfaceBrushValue(previous ?? .init())
            let previousMask = original.mask(at: point, id: settings.maskID)
            var maskValue = previousMask
            for dab in dabs {
                visits += 1
                if visits.isMultiple(of: 1_024) { try Task.checkCancellation() }
                let weight = abs(TerrainBrushMask.weight(point: point, source: source, dab: dab, settings: mask))
                let amount = Float(min(1, weight * Double(dab.pressure) * Double(settings.strength)))
                guard amount > 0 else { continue }
                if settings.operation == .paintMask {
                    maskValue = maskValue * (1 - amount) + settings.maskValue * amount
                } else { value.apply(settings, amount: amount) }
            }
            if settings.operation == .paintMask {
                if maskValue != previousMask { masks.append(.init(point: point, maskID: settings.maskID, value: maskValue)) }
            } else {
                let paint = value.paint.isEmpty ? nil : value.paint
                if paint != previous { surface.append(.init(point: point, paint: paint)) }
            }
        }
        return (surface, masks, visits)
    }
}

private struct TerrainSurfaceBrushValue {
    var ids: SIMD4<UInt16>
    var weights: Vector4
    var strength: Float
    var tint: Vector4
    var tintStrength: Float
    var roughness: Float
    var roughnessStrength: Float

    init(_ value: TerrainSurfacePaint) {
        ids = value.layerIDs; weights = value.weights; strength = value.overrideStrength
        tint = value.tint; tintStrength = value.tintStrength; roughness = value.roughness; roughnessStrength = value.roughnessStrength
    }

    var paint: TerrainSurfacePaint {
        .init(layerIDs: ids, weights: weights, overrideStrength: strength, tint: tint, tintStrength: tintStrength, roughness: roughness, roughnessStrength: roughnessStrength)
    }

    mutating func apply(_ settings: TerrainSurfaceBrushSettings, amount: Float) {
        switch settings.operation {
        case .paintLayer: blendLayer(settings.layerID, amount: amount)
        case .eraseLayer:
            strength *= 1 - amount
            if strength == 0 { ids = .zero; weights = .zero }
        case .paintTint:
            let next = tintStrength * (1 - amount) + amount
            tint = (tint * (tintStrength * (1 - amount)) + settings.tint * amount) / next
            tintStrength = next
        case .eraseTint: tintStrength *= 1 - amount
        case .paintRoughness:
            let next = roughnessStrength * (1 - amount) + amount
            roughness = (roughness * roughnessStrength * (1 - amount) + settings.roughness * amount) / next
            roughnessStrength = next
        case .eraseRoughness: roughnessStrength *= 1 - amount
        case .paintMask: break
        }
    }

    private mutating func blendLayer(_ target: UInt16, amount: Float) {
        var candidates = SIMD8<UInt16>(repeating: 0), values = SIMD8<Float>(repeating: 0)
        var targetIndex = 4
        for channel in 0..<4 {
            candidates[channel] = ids[channel]
            values[channel] = weights[channel] * strength * (1 - amount)
            if weights[channel] > 0, ids[channel] == target { targetIndex = channel }
        }
        candidates[targetIndex] = target
        values[targetIndex] += amount
        strength = strength * (1 - amount) + amount
        ids = .zero; weights = .zero
        var total: Float = 0
        for channel in 0..<4 {
            var best = 0
            for index in 1..<5 where values[index] > values[best] || (values[index] == values[best] && candidates[index] < candidates[best]) { best = index }
            guard values[best] > 0 else { break }
            ids[channel] = candidates[best]; weights[channel] = values[best]; total += values[best]
            values[best] = -1
        }
        if total > 0 { weights /= total }
    }
}
