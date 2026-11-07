import AdaAssets
import Foundation
import Math

public enum TerrainVolumeFieldError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidCoordinate
    case missingMesh
    case mismatchedMesh
    case memoryBudgetExceeded
    case workBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid terrain volume field configuration"
        case .invalidCoordinate: "Terrain volume coordinates exceed the supported lattice or precision"
        case .missingMesh: "Prepare the enabled static mesh operand before evaluating the volume"
        case .mismatchedMesh: "The prepared mesh does not match this operation's source and placement"
        case .memoryBudgetExceeded: "Terrain volume brick exceeds its allocation budget"
        case .workBudgetExceeded: "Terrain volume evaluation exceeds its sample work budget"
        }
    }
}

/// Prepared closed mesh with the exact source identity and complete operation transform.
public struct TerrainVolumePreparedMesh: Sendable {
    let generation = UUID()
    let operationID: UUID
    let operand: TerrainVolumeOperand
    let transform: Transform3D
    let solid: ScalarMeshSolid

    public init(operation: TerrainVolumeOperation, positions: [Vector3], indices: [UInt32], maximumValidationWork: Int = 8_388_608) throws {
        try operation.validate()
        guard case .mesh = operation.operand else { throw TerrainVolumeFieldError.mismatchedMesh }
        operationID = operation.id; operand = operation.operand; transform = operation.transform
        solid = try ScalarMeshSolid(positions: positions, indices: indices, transform: operation.transform, maximumValidationWork: maximumValidationWork)
    }
}

public struct TerrainVolumeDensitySample: Sendable {
    public let value: Float
    public let materialTag: UInt32
}

/// Immutable COW base and ordered operand generation for bounded worker evaluation.
public struct TerrainVolumeField: Sendable {
    /// Conservative sample/dependency array charge with staging capacity and allocator overhead.
    public static let brickAllocationBytes = TerrainVolumeBrickAsset.sampleCount * 16 + 12_288
        + TerrainVolumeBrickDependency.maximumBaseCells * MemoryLayout<TerrainVolumeBaseCell>.stride * 2
        + TerrainVolumeDocumentAsset.maximumOperations * MemoryLayout<TerrainVolumeOperandDependency>.stride * 2
    public let document: TerrainVolumeDocumentAsset
    public let baseRevision: UInt64
    private let base: TerrainHeightStorage
    private let operands: [TerrainVolumeFieldOperand]
    private let interiorLayerID: UInt16?
    private let maximumMeshSampleWork: Int
    var volumeOperandBounds: [AABB] { operands.map { $0.shape.bounds } }
    private var band: Float { document.cellSize * 2 }

    public init(
        document: TerrainVolumeDocumentAsset,
        base: TerrainHeightStorage,
        preparedMeshes: [TerrainVolumePreparedMesh] = [],
        interiorLayerID: UInt16? = nil,
        maximumMeshSampleWork: Int = 4_096
    ) throws {
        try document.validate()
        guard preparedMeshes.count <= TerrainVolumeDocumentAsset.maximumOperations, (1...1_048_576).contains(maximumMeshSampleWork) else {
            throw TerrainVolumeFieldError.invalidConfiguration
        }
        var meshes: [UUID: TerrainVolumePreparedMesh] = [:]
        for mesh in preparedMeshes {
            guard meshes.updateValue(mesh, forKey: mesh.operationID) == nil else { throw TerrainVolumeFieldError.mismatchedMesh }
        }
        var operands: [TerrainVolumeFieldOperand] = []
        for record in document.operations where record.isEnabled {
            try Task.checkCancellation()
            let shape: TerrainVolumeFieldShape
            switch record.operand {
            case let .primitive(primitive): shape = .primitive(try ScalarSolid(primitive: primitive, transform: record.transform))
            case .mesh:
                guard let mesh = meshes[record.id] else { throw TerrainVolumeFieldError.missingMesh }
                guard mesh.operand == record.operand, mesh.transform == record.transform else { throw TerrainVolumeFieldError.mismatchedMesh }
                shape = .mesh(mesh.solid, mesh.generation)
            }
            operands.append(.init(record: record, shape: shape))
        }
        let revision = base.revision
        self.base = try base.snapshotForBrush(expectedRevision: revision)
        self.document = document; baseRevision = revision; self.operands = operands
        self.interiorLayerID = interiorLayerID; self.maximumMeshSampleWork = maximumMeshSampleWork
    }

    /// Base distances preserve the heightfield's planes. Operands use a two-cell narrow
    /// band and expanded conservative support, independent of brick boundaries.
    /// Work charges mesh queries at their configured conservative per-query allowance.
    public func sample(at point: Vector3, maximumWork: Int = 1_048_576) throws -> TerrainVolumeDensitySample {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { throw TerrainVolumeFieldError.invalidCoordinate }
        var budget = try TerrainVolumeFieldWork(maximumWork)
        return try evaluate(point, operands: operands, budget: &budget)
    }

    func sample(at point: Vector3, budget: inout TerrainVolumeFieldWork) throws -> TerrainVolumeDensitySample {
        try evaluate(point, operands: operands, budget: &budget)
    }

    /// Builds private arrays only; publication and collider replacement are separate operations.
    public func makeBrick(
        x: Int32,
        y: Int32,
        z: Int32,
        maximumBytes: Int = Self.brickAllocationBytes,
        maximumWork: Int = 268_435_456
    ) throws -> TerrainVolumeBrickAsset {
        var budget = try TerrainVolumeFieldWork(maximumWork)
        return try buildBrick(x: x, y: y, z: z, maximumBytes: maximumBytes, budget: &budget)
    }

    func buildBrick(x: Int32, y: Int32, z: Int32, maximumBytes: Int, budget: inout TerrainVolumeFieldWork) throws -> TerrainVolumeBrickAsset {
        try Task.checkCancellation()
        guard (-32_768..<32_768).contains(x), (-32_768..<32_768).contains(y), (-32_768..<32_768).contains(z) else {
            throw TerrainVolumeFieldError.invalidCoordinate
        }
        guard maximumBytes >= Self.brickAllocationBytes else { throw TerrainVolumeFieldError.memoryBudgetExceeded }
        let offset = SIMD3(Int64(x) * 32, Int64(y) * 32, Int64(z) * 32)
        let low = position(offset), high = position(SIMD3(offset.x + 32, offset.y + 32, offset.z + 32))
        for axis in 0..<3 {
            var previous = low[axis]
            guard previous.isFinite else { throw TerrainVolumeFieldError.invalidCoordinate }
            for index in 1...32 {
                var address = offset; address[axis] += Int64(index)
                let next = position(address)[axis]
                guard next.isFinite, next > previous else { throw TerrainVolumeFieldError.invalidCoordinate }
                previous = next
            }
        }
        var relevant: [TerrainVolumeFieldOperand] = []
        for operand in operands {
            try budget.spend()
            if operand.overlaps(low, high, padding: band) { relevant.append(operand) }
        }
        guard budget.remaining >= TerrainVolumeBrickAsset.sampleCount else { throw TerrainVolumeFieldError.workBudgetExceeded }
        var values: [Float] = [], tags: [UInt32] = []
        values.reserveCapacity(TerrainVolumeBrickAsset.sampleCount); tags.reserveCapacity(TerrainVolumeBrickAsset.sampleCount)
        for z in 0...32 {
            for y in 0...32 {
                for x in 0...32 {
                    let point = position(SIMD3(offset.x + Int64(x), offset.y + Int64(y), offset.z + Int64(z)))
                    let sample = try evaluate(point, operands: relevant, budget: &budget)
                    values.append(sample.value); tags.append(sample.materialTag)
                }
            }
        }
        return .init(x: x, y: y, z: z, values: values, materialTags: tags)
    }

    /// Extracts this generation's canonical brick, without installing terrain or collision resources.
    public func surface(of brick: TerrainVolumeBrickAsset, maximumTriangles: Int = 262_144) throws -> ScalarSurfaceMesh {
        try brick.validate()
        let grid = try ScalarFieldGrid(
            origin: document.origin,
            spacing: document.cellSize,
            cellCount: [32, 32, 32],
            values: brick.values,
            cellOffset: SIMD3(brick.x * 32, brick.y * 32, brick.z * 32)
        )
        return try ScalarFieldSurface.extract(grid, maximumTriangles: maximumTriangles, diagonal: .fallingXZ)
    }

    private func position(_ address: SIMD3<Int64>) -> Vector3 {
        Vector3(
            document.origin.x + Float(address.x) * document.cellSize,
            document.origin.y + Float(address.y) * document.cellSize,
            document.origin.z + Float(address.z) * document.cellSize
        )
    }

    private func evaluate(_ point: Vector3, operands: [TerrainVolumeFieldOperand], budget: inout TerrainVolumeFieldWork) throws -> TerrainVolumeDensitySample {
        try budget.spend()
        let height = base.heightForAnchor(at: [point.x, point.z])
        let limit = Double(Float.greatestFiniteMagnitude)
        var value = height.map { Float(max(-limit, min(limit, Double(point.y) - Double($0)))) } ?? band
        var tag = TerrainVolumeBrickAsset.unassignedMaterial
        for operand in operands {
            try budget.spend()
            guard operand.overlaps(point, point, padding: band) else { continue }
            let raw: Float
            switch operand.shape {
            case let .primitive(solid): raw = try solid.value(at: point)
            case let .mesh(solid, _):
                try budget.spend(maximumMeshSampleWork)
                raw = try solid.value(at: point, maximumWork: maximumMeshSampleWork)
            }
            let density = max(-band, min(band, raw))
            switch operand.record.operation {
            case .union:
                if density <= value { value = density; tag = operand.record.layerID.map(UInt32.init) ?? TerrainVolumeBrickAsset.unassignedMaterial }
            case .subtract:
                if -density >= value {
                    value = -density
                    tag = (operand.record.layerID ?? interiorLayerID).map(UInt32.init) ?? TerrainVolumeBrickAsset.unassignedMaterial
                }
            }
        }
        return .init(value: value, materialTag: tag)
    }
}

private enum TerrainVolumeFieldShape: Sendable {
    case primitive(ScalarSolid)
    case mesh(ScalarMeshSolid, UUID)

    var bounds: AABB {
        switch self {
        case let .primitive(solid): solid.bounds
        case let .mesh(solid, _): solid.bounds
        }
    }
}

private struct TerrainVolumeFieldOperand: Sendable {
    let record: TerrainVolumeOperation
    let shape: TerrainVolumeFieldShape

    func overlaps(_ low: Vector3, _ high: Vector3, padding: Float) -> Bool {
        let bounds = shape.bounds, minimum = bounds.min, maximum = bounds.max
        for axis in 0..<3 {
            if Double(high[axis]) < Double(minimum[axis]) - Double(padding) || Double(low[axis]) > Double(maximum[axis]) + Double(padding) {
                return false
            }
        }
        return true
    }
}

struct TerrainVolumeFieldWork {
    private(set) var remaining: Int

    init(_ maximum: Int) throws {
        try Task.checkCancellation()
        guard maximum >= 0 else { throw TerrainVolumeFieldError.workBudgetExceeded }
        remaining = maximum
    }

    mutating func spend(_ count: Int = 1) throws {
        guard count <= remaining else { throw TerrainVolumeFieldError.workBudgetExceeded }
        if remaining.isMultiple(of: 256) || count >= 256 { try Task.checkCancellation() }
        remaining -= count
    }
}

extension TerrainVolumeField {
    func cacheDependency(at coordinate: TerrainVolumeBrickCoordinate, budget: inout TerrainVolumeFieldWork) throws -> TerrainVolumeBrickDependency {
        guard (-32_768..<32_768).contains(coordinate.x), (-32_768..<32_768).contains(coordinate.y), (-32_768..<32_768).contains(coordinate.z) else {
            throw TerrainVolumeFieldError.invalidCoordinate
        }
        let offset = SIMD3(Int64(coordinate.x) * 32, Int64(coordinate.y) * 32, Int64(coordinate.z) * 32)
        let low = position(offset), high = position(SIMD3(offset.x + 32, offset.y + 32, offset.z + 32))
        for axis in 0..<3 {
            guard low[axis].isFinite, high[axis].isFinite, high[axis] > low[axis] else { throw TerrainVolumeFieldError.invalidCoordinate }
        }
        var selected: [TerrainVolumeOperandDependency] = []
        for operand in operands {
            try budget.spend()
            guard operand.overlaps(low, high, padding: band + document.cellSize) else { continue }
            let generation: UUID?
            switch operand.shape {
            case .primitive: generation = nil
            case let .mesh(_, id): generation = id
            }
            selected.append(.init(operation: operand.record, meshGeneration: generation))
        }
        return try .init(
            baseIdentity: base.volumeBaseIdentity,
            baseCells: baseCells(low: low - Vector3(document.cellSize), high: high + Vector3(document.cellSize), budget: &budget),
            origin: document.origin,
            cellSize: document.cellSize,
            interiorLayerID: interiorLayerID,
            operands: selected
        )
    }

    private func baseCells(low: Vector3, high: Vector3, budget: inout TerrainVolumeFieldWork) throws -> [TerrainVolumeBaseCell] {
        let spacing = Double(base.spacing), limit = Double(TerrainHeightStorage.gridLimit)
        let lowX = ((Double(low.x) - Double(base.origin.x)) / spacing).rounded(.down) - 1
        let lowZ = ((Double(low.z) - Double(base.origin.y)) / spacing).rounded(.down) - 1
        let highX = ((Double(high.x) - Double(base.origin.x)) / spacing).rounded(.down) + 1
        let highZ = ((Double(high.z) - Double(base.origin.y)) / spacing).rounded(.down) + 1
        guard lowX <= limit, lowZ <= limit, highX >= -limit, highZ >= -limit else {
            return []
        }
        func tile(_ value: Double) -> Int {
            let sample = Int(max(-limit, min(limit, value))), size = TerrainHeightStorage.cellsPerTile
            return sample / size - (sample < 0 && sample % size != 0 ? 1 : 0)
        }
        let firstX = tile(lowX), firstZ = tile(lowZ), lastX = tile(highX), lastZ = tile(highZ)
        let width = lastX - firstX + 1, depth = lastZ - firstZ + 1, maximum = TerrainVolumeBrickDependency.maximumBaseCells
        guard width > 0, depth > 0, width <= maximum, depth <= maximum / width else { throw TerrainVolumeFieldError.workBudgetExceeded }
        var result: [TerrainVolumeBaseCell] = []
        result.reserveCapacity(width * depth)
        for z in firstZ...lastZ {
            for x in firstX...lastX {
                try budget.spend()
                result.append(base.volumeBaseCell(at: .init(x: x, z: z)))
            }
        }
        return result
    }
}
