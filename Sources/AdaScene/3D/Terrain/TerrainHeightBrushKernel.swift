import Foundation
import Math

struct TerrainBrushBounds {
    let minX: Int
    let maxX: Int
    let minZ: Int
    let maxZ: Int
    var area: Int {
        // WASM uses 32-bit Int; an enormous clipped box must fail the work budget, not trap.
        let product = (maxX - minX + 1).multipliedReportingOverflow(by: maxZ - minZ + 1)
        return product.overflow ? Int.max : product.partialValue
    }

    init?(source: TerrainHeightStorage, dab: TerrainBrushDab, settings: TerrainHeightBrushSettings) {
        let r = Double(settings.radius) / Double(source.spacing)
        let c = abs(dab.cosine), s = abs(dab.sine)
        let rx: Double, rz: Double
        switch settings.shape {
        case .square, .alpha: rx = r * (c + s); rz = rx
        case .ridge: rx = r * (c + 0.25 * s); rz = r * (s + 0.25 * c)
        case .softRound, .hardRound, .crater, .ridgedNoise: rx = r; rz = r
        }
        let x = (Double(dab.center.x) - Double(source.origin.x)) / Double(source.spacing)
        let z = (Double(dab.center.y) - Double(source.origin.y)) / Double(source.spacing)
        let limit = Double(TerrainHeightStorage.gridLimit)
        let x0 = max(-limit, (x - rx).rounded(.down)), x1 = min(limit, (x + rx).rounded(.up))
        let z0 = max(-limit, (z - rz).rounded(.down)), z1 = min(limit, (z + rz).rounded(.up))
        guard x0 <= x1, z0 <= z1 else {
            return nil
        }
        minX = Int(x0); maxX = Int(x1); minZ = Int(z0); maxZ = Int(z1)
    }
}

struct TerrainHeightBrushKernel {
    let source: TerrainHeightStorage
    let stroke: TerrainHeightBrushStroke
    let dabs: [TerrainBrushDab]
    let points: [TerrainGridPoint]
    let indices: [TerrainGridPoint: Int]
    let original: [TerrainGridPoint: Float]
    let mask: [Double]
    let flattenHeight: Double
    var values: [Float]

    init(source: TerrainHeightStorage, stroke: TerrainHeightBrushStroke, plan: TerrainHeightBrushPlan) throws {
        guard let start = stroke.points.first,
            let height = source.height(at: [start.position.x, start.position.z])
        else { throw TerrainHeightBrushError.missingSurface }
        self.source = source
        self.stroke = stroke
        self.dabs = plan.dabs
        flattenHeight = Double(stroke.settings.targetHeight ?? height)
        let footprint = plan.footprint, reads = plan.reads
        var original: [TerrainGridPoint: Float] = [:]
        for point in reads {
            if original.count.isMultiple(of: 256) { try Task.checkCancellation() }
            if let value = source.heightForBrush(at: point) { original[point] = value }
        }
        let points = footprint.filter { source.height(atSample: $0) != nil }.sorted { $0.z == $1.z ? $0.x < $1.x : $0.z < $1.z }
        self.points = points
        self.original = original
        indices = Dictionary(uniqueKeysWithValues: points.enumerated().map { ($0.element, $0.offset) })
        values = points.map { original[$0] ?? 0 }
        mask = points.map { point in
            let height = original[point] ?? 0
            if let range = stroke.settings.heightRange, !range.contains(height) {
                return 0
            }
            if let range = stroke.settings.slopeRange {
                guard let normal = source.normalForBrush(at: point) else {
                    return 0
                }
                let nx = Double(normal.x), nz = Double(normal.z)
                let degrees = Float(Math.atan2((nx * nx + nz * nz).squareRoot(), Double(normal.y)) * 180 / Double.pi)
                if !range.contains(degrees) {
                    return 0
                }
            }
            return 1
        }
    }

    mutating func evaluate() throws -> [TerrainHeightUpdate] {
        for dab in dabs where dab.pressure > 0 {
            try Task.checkCancellation()
            if stroke.settings.operation == .talus { try relax(dab); continue }
            let previous = values
            for index in points.indices {
                let point = points[index]
                let weight = TerrainBrushMask.weight(point: point, source: source, dab: dab, settings: stroke.settings) * mask[index]
                guard weight != 0 else { continue }
                let amount = Double(stroke.settings.strength) * Double(dab.exposure) * Double(dab.pressure)
                let current = Double(previous[index])
                let next: Double
                switch stroke.settings.operation {
                case .raise: next = current + amount * weight
                case .lower: next = current - amount * weight
                case .flatten: next = blend(current, target: flattenHeight, amount: amount * abs(weight))
                case .setHeight: next = blend(current, target: Double(stroke.settings.targetHeight ?? 0), amount: amount * abs(weight))
                case .ramp: next = blend(current, target: rampHeight(point), amount: amount * abs(weight))
                case .terrace:
                    let step = Double(stroke.settings.terraceStep), offset = Double(stroke.settings.targetHeight ?? 0)
                    let target = ((Double(original[point] ?? 0) - offset) / step).rounded() * step + offset
                    next = blend(current, target: target, amount: amount * abs(weight))
                case .noise:
                    let noise = TerrainBrushMask.random(x: point.x, z: point.z, seed: stroke.settings.seed)
                    let target = Double(original[point] ?? 0) + noise * Double(stroke.settings.noiseAmplitude)
                    next = blend(current, target: target, amount: amount * abs(weight))
                case .smooth:
                    var sum = 0.0
                    for z in -1...1 {
                        for x in -1...1 {
                            let neighbor = TerrainGridPoint(x: point.x + x, z: point.z + z)
                            sum += Double(indices[neighbor].map { previous[$0] } ?? original[neighbor] ?? previous[index])
                        }
                    }
                    next = blend(current, target: sum / 9, amount: amount * abs(weight))
                case .talus: continue
                }
                values[index] = try checked(next)
            }
        }
        return points.indices.compactMap { index in
            let point = points[index]
            return values[index] == original[point] ? nil : .init(point: point, height: values[index])
        }
    }

    private func blend(_ value: Double, target: Double, amount: Double) -> Double { value + (target - value) * min(1, max(0, amount)) }

    private func checked(_ value: Double) throws -> Float {
        guard value.isFinite, abs(value) <= Double(Float.greatestFiniteMagnitude) else { throw TerrainHeightBrushError.invalidParameters }
        return Float(value)
    }

    private func rampHeight(_ point: TerrainGridPoint) -> Double {
        guard let a = stroke.points.first?.position, let b = stroke.points.last?.position else {
            return 0
        }
        let dx = Double(b.x) - Double(a.x), dz = Double(b.z) - Double(a.z)
        let x = Double(source.origin.x) + Double(point.x) * Double(source.spacing) - Double(a.x)
        let z = Double(source.origin.y) + Double(point.z) * Double(source.spacing) - Double(a.z)
        let t = min(1, max(0, (x * dx + z * dz) / (dx * dx + dz * dz)))
        return Double(a.y) + (Double(b.y) - Double(a.y)) * t
    }

    private mutating func relax(_ dab: TerrainBrushDab) throws {
        let radians = Double(stroke.settings.talusAngle) * Double.pi / 180
        let threshold = Math.sin(radians) / Math.cos(radians) * Double(source.spacing)
        let amount = min(0.25, Double(stroke.settings.strength) * Double(dab.exposure) * Double(dab.pressure) / Double(stroke.settings.iterations)) * 0.25
        let weights = points.indices.map { abs(TerrainBrushMask.weight(point: points[$0], source: source, dab: dab, settings: stroke.settings)) * mask[$0] }
        var flux = Array(repeating: 0.0, count: points.count)
        for _ in 0..<stroke.settings.iterations {
            try Task.checkCancellation()
            for index in flux.indices { flux[index] = 0 }
            for index in points.indices where weights[index] > 0 {
                let point = points[index]
                for direction in 0..<2 {
                    let neighbor = TerrainGridPoint(x: point.x + (direction == 0 ? 1 : 0), z: point.z + (direction == 1 ? 1 : 0))
                    guard let other = indices[neighbor], weights[other] > 0 else { continue }
                    let difference = Double(values[index]) - Double(values[other])
                    let transfer = max(0, abs(difference) - threshold) * amount * min(weights[index], weights[other]) * (difference >= 0 ? 1 : -1)
                    flux[index] -= transfer
                    flux[other] += transfer
                }
            }
            for index in points.indices { values[index] = try checked(Double(values[index]) + flux[index]) }
        }
    }
}

extension TerrainHeightStorage {
    func stagedBrush(_ stroke: TerrainHeightBrushStroke, expectedRevision: UInt64, plan: TerrainHeightBrushPlan? = nil) throws -> (storage: TerrainHeightStorage, delta: TerrainHeightDelta) {
        let source = try snapshotForBrush(expectedRevision: expectedRevision)
        let resolved = try plan ?? TerrainHeightBrushPlan(source: source, stroke: stroke)
        var kernel = try TerrainHeightBrushKernel(source: source, stroke: stroke, plan: resolved)
        return try stagedHeights(kernel.evaluate(), expectedRevision: expectedRevision)
    }
}
