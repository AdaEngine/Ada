import Math

struct TerrainInstanceBrushBounds: Sendable {
    let minX: Double
    let maxX: Double
    let minZ: Double
    let maxZ: Double

    init?(source: TerrainHeightStorage, dab: TerrainBrushDab, settings: TerrainInstanceBrushSettings, margin: Double = 0) {
        let radius = Double(settings.radius), cosine = abs(dab.cosine), sine = abs(dab.sine)
        let rx: Double, rz: Double
        switch settings.shape {
        case .square, .alpha: rx = radius * (cosine + sine); rz = rx
        case .ridge: rx = radius * (cosine + 0.25 * sine); rz = radius * (sine + 0.25 * cosine)
        case .softRound, .hardRound, .crater, .ridgedNoise: rx = radius; rz = radius
        }
        let x = Double(dab.center.x) - Double(source.origin.x), z = Double(dab.center.y) - Double(source.origin.y)
        let limit = Double(TerrainHeightStorage.gridLimit) * Double(source.spacing)
        minX = max(-limit, x - rx - margin); maxX = min(limit, x + rx + margin)
        minZ = max(-limit, z - rz - margin); maxZ = min(limit, z + rz + margin)
        guard minX <= maxX, minZ <= maxZ else {
            return nil
        }
    }

    func contains(_ point: TerrainInstancePoint) -> Bool { point.x >= minX && point.x <= maxX && point.z >= minZ && point.z <= maxZ }

    func intersects(minX: Double, minZ: Double, size: Double) -> Bool {
        minX <= self.maxX && minX + size >= self.minX && minZ <= self.maxZ && minZ + size >= self.minZ
    }
}

/// Plans a distance-spaced deterministic gesture before loading or allocating authored rows.
struct TerrainInstanceBrushPlan: Sendable {
    static let maximumCandidates = 262_144
    static let maximumVisits = 1_048_576
    let dabs: [TerrainBrushDab]
    let bounds: [TerrainInstanceBrushBounds]
    let readBounds: [TerrainInstanceBrushBounds]
    let candidates: [TerrainInstanceSampleKey]
    let step: Double
    let maskSettings: TerrainHeightBrushSettings

    init(source: TerrainHeightStorage, stroke: TerrainInstanceBrushStroke) throws {
        try stroke.validate()
        let settings = stroke.settings
        var mask = TerrainHeightBrushSettings(operation: .noise, radius: settings.radius, strength: settings.strength)
        mask.shape = settings.shape; mask.falloff = settings.falloff; mask.spacing = settings.spacing
        mask.rotation = settings.rotation; mask.rotationJitter = settings.rotationJitter; mask.seed = settings.seed
        let sampled = try TerrainHeightBrushStroke(settings: mask, points: stroke.points).sampledDabs()
        step = Double(settings.minimumDistance) / Double(2).squareRoot()
        maskSettings = mask
        if settings.strength == 0 || (settings.operation == .paint && settings.density == 0) {
            dabs = []; bounds = []; readBounds = []; candidates = []
            return
        }
        dabs = sampled.filter { $0.pressure > 0 }
        bounds = dabs.compactMap { TerrainInstanceBrushBounds(source: source, dab: $0, settings: settings) }
        let margin = settings.operation == .paint ? Double(settings.minimumDistance) : 0
        readBounds = dabs.compactMap { TerrainInstanceBrushBounds(source: source, dab: $0, settings: settings, margin: margin) }
        var keys: Set<TerrainInstanceSampleKey> = []
        var visits = 0
        if settings.operation == .paint {
            for box in bounds {
                try Task.checkCancellation()
                let first = try TerrainInstanceSampleKey(point: .init(x: box.minX, z: box.minZ), step: step)
                let last = try TerrainInstanceSampleKey(point: .init(x: box.maxX, z: box.maxZ), step: step)
                let width = last.x - first.x + 1, depth = last.z - first.z + 1
                guard width <= Int64(Self.maximumCandidates), depth <= Int64(Self.maximumCandidates) else { throw TerrainInstanceBrushError.workBudgetExceeded }
                let area = Int(width).multipliedReportingOverflow(by: Int(depth))
                guard !area.overflow, area.partialValue <= Self.maximumVisits - visits else { throw TerrainInstanceBrushError.workBudgetExceeded }
                visits += area.partialValue
                for z in first.z...last.z {
                    for x in first.x...last.x {
                        keys.insert(.init(x: x, z: z))
                        guard keys.count <= Self.maximumCandidates else { throw TerrainInstanceBrushError.workBudgetExceeded }
                    }
                }
            }
        }
        guard keys.count <= Self.maximumVisits / max(1, dabs.count) else { throw TerrainInstanceBrushError.workBudgetExceeded }
        candidates = keys.sorted()
    }

    func regions(source: TerrainHeightStorage, allowed: Set<TerrainRegionCoordinate>, maximum: Int) throws -> Set<TerrainRegionCoordinate> {
        var result: Set<TerrainRegionCoordinate> = []
        let scale = Double(source.spacing) * 256
        var visits = 0
        for box in readBounds {
            try Task.checkCancellation()
            let minX = max(-4_096, Int((box.minX / scale).rounded(.down))), maxX = min(4_096, Int((box.maxX / scale).rounded(.down)))
            let minZ = max(-4_096, Int((box.minZ / scale).rounded(.down))), maxZ = min(4_096, Int((box.maxZ / scale).rounded(.down)))
            let area = (maxX - minX + 1).multipliedReportingOverflow(by: maxZ - minZ + 1)
            guard !area.overflow, area.partialValue <= Self.maximumVisits - visits else { throw TerrainInstanceBrushError.workBudgetExceeded }
            visits += area.partialValue
            for z in minZ...maxZ {
                for x in minX...maxX where allowed.contains(.init(x: x, z: z)) {
                    result.insert(.init(x: x, z: z))
                    guard result.count <= maximum else { throw TerrainRegionCache.CacheError.regionBudgetExceeded }
                }
            }
        }
        return result
    }

    static func hash(x: Int64, z: Int64, prototype: UInt16, seed: UInt64) -> UInt64 {
        var value = UInt64(bitPattern: x) &* 0x9e37_79b9_7f4a_7c15
        value ^= UInt64(bitPattern: z) &* 0xbf58_476d_1ce4_e5b9
        value ^= seed &+ (UInt64(prototype) &* 0x94d0_49bb_1331_11eb)
        return mix(value)
    }

    static func mix(_ input: UInt64) -> UInt64 {
        var value = input
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }

    static func unit(_ value: UInt64) -> Double { Double(mix(value) >> 11) / 9_007_199_254_740_992 }
}
