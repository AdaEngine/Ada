import AdaAssets
import Math

/// Gesture-local cache of the same canonical material field used by terrain rendering.
struct TerrainInstanceMaterialFilter {
    private let source: TerrainHeightStorage
    private let surface: TerrainSurfaceStorageRows
    private let resolver: TerrainMaterialResolver
    private let layer: UInt16
    private let minimumWeight: Float
    private var samples: [TerrainGridPoint: Float] = [:]

    static func make(source: TerrainHeightStorage, palette: TerrainMaterialPalette?, settings: TerrainInstanceBrushSettings) throws -> Self? {
        guard let layer = settings.materialLayerID else {
            return nil
        }
        guard let palette, palette.layers.contains(where: { $0.id == layer }) else { throw TerrainInstanceBrushError.missingMaterialLayer }
        return try .init(source: source, surface: source.surfaceSnapshot(), resolver: TerrainMaterialResolver(palette), layer: layer, minimumWeight: settings.minimumMaterialWeight)
    }

    mutating func accepts(grid: Vector2, visits: inout Int) throws -> Bool {
        let x = Int(grid.x.rounded(.down)), z = Int(grid.y.rounded(.down))
        let fx = grid.x - Float(x), fz = grid.y - Float(z)
        // Difference-form lerps preserve constant coverage exactly, including threshold one.
        // Resolve stable IDs first; numeric layer IDs are never interpolated.
        let bottom = try row(x: x, z: z, fraction: fx, visits: &visits)
        var weight = bottom
        if fz > 0 {
            let top = try row(x: x, z: z + 1, fraction: fx, visits: &visits)
            weight += (top - bottom) * fz
        }
        return weight > 0 && weight >= minimumWeight
    }

    private mutating func row(x: Int, z: Int, fraction: Float, visits: inout Int) throws -> Float {
        let first = try sample(at: .init(x: x, z: z), visits: &visits)
        guard fraction > 0 else {
            return first
        }
        let second = try sample(at: .init(x: x + 1, z: z), visits: &visits)
        return first + (second - first) * fraction
    }

    private mutating func sample(at point: TerrainGridPoint, visits: inout Int) throws -> Float {
        if let weight = samples[point] {
            return weight
        }
        let cost = resolver.evaluationWorkCost
        guard samples.count < 65_536, cost <= TerrainInstanceBrushPlan.maximumVisits - visits else { throw TerrainInstanceBrushError.workBudgetExceeded }
        visits += cost
        if samples.count.isMultiple(of: 256) { try Task.checkCancellation() }
        guard let height = source.heightForBrush(at: point), let normal = source.normalForBrush(at: point, includeNormalCoverage: true) else {
            samples[point] = 0
            return 0
        }
        let position = source.origin + Vector2(Float(point.x), Float(point.z)) * source.spacing
        let curvature = resolver.needsCurvature ? TerrainSourceMaterials.curvature(x: point.x, z: point.z, center: Double(height), storage: source) : 0
        let sample = try resolver.resolve(
            position: [position.x, height, position.y],
            normal: normal,
            curvature: curvature,
            paint: surface.sample(at: point),
            mask: { surface.mask(at: point, id: $0) }
        )
        var weight: Float = 0
        for channel in 0..<4 where sample.ids[channel] == Float(layer) { weight += sample.weights[channel] }
        samples[point] = weight
        return weight
    }
}
