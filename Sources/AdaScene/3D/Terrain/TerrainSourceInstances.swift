import AdaAssets
import AdaECS
import AdaRender
import AdaTransform
import Foundation
import Math

struct TerrainInstanceCellKey: Hashable, Sendable, Comparable {
    let coordinate: TerrainTileCoordinate
    let prototype: UInt16
    let verticalBand: Int
    let cellScaleBits: UInt32

    init(coordinate: TerrainTileCoordinate, prototype: UInt16, verticalBand: Int = 0, cellScaleBits: UInt32 = 0) {
        self.coordinate = coordinate
        self.prototype = prototype
        self.verticalBand = verticalBand
        self.cellScaleBits = cellScaleBits
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.coordinate != rhs.coordinate { return lhs.coordinate < rhs.coordinate }
        if lhs.verticalBand != rhs.verticalBand { return lhs.verticalBand < rhs.verticalBand }
        if lhs.cellScaleBits != rhs.cellScaleBits { return lhs.cellScaleBits < rhs.cellScaleBits }
        return lhs.prototype < rhs.prototype
    }
}

struct TerrainPreparedInstanceCell: Sendable {
    let id = UUID()
    let inputID: UUID
    let instanceCount: Int
    let batches: [Mesh3DInstancesComponent]
    let maximumDistance: Float?
    let collisionPlacements: [TerrainCollisionPlacement]
    let meshInput: MeshTerrainInstanceCellInput?

    init(inputID: UUID, instanceCount: Int, batches: [Mesh3DInstancesComponent], maximumDistance: Float?,
         collisionPlacements: [TerrainCollisionPlacement] = [], meshInput: MeshTerrainInstanceCellInput? = nil) {
        self.inputID = inputID; self.instanceCount = instanceCount; self.batches = batches; self.maximumDistance = maximumDistance; self.collisionPlacements = collisionPlacements
        self.meshInput = meshInput
    }
}

struct TerrainSourceInstanceCell: Sendable {
    let prepared: TerrainPreparedInstanceCell
    let entities: [Entity.ID]
}

enum TerrainSourceInstances {
    static func prepare(
        storage: TerrainHeightStorage,
        residency: TerrainSourceResidency?,
        previous: [TerrainInstanceCellKey: TerrainPreparedInstanceCell],
        maximumBytes: Int
    ) async throws -> (cells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell], residency: TerrainSourceResidency?, groupedRecordCount: Int) {
        guard var residency else {
            return ([:], nil, 0)
        }
        let palette = Dictionary(uniqueKeysWithValues: residency.cache.manifest.meshPrototypes.map { ($0.id, $0) })
        var cells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell] = [:]
        var groupedRecordCount = 0
        var remaining = maximumBytes
        var charged: Set<UInt16> = []
        let previousByCoordinate = Dictionary(grouping: previous, by: { $0.key.coordinate })
        func charge(_ prototype: TerrainMeshPrototype, id: UInt16, count: Int) throws {
            if charged.insert(id).inserted {
                guard remaining >= prototype.retainedGeometryBytes else { throw TerrainSourceError.meshBudgetExceeded }
                remaining -= prototype.retainedGeometryBytes
            }
            let stride = MemoryLayout<Mesh3DInstance>.stride
            guard count <= remaining / stride / max(1, prototype.parts.count) else { throw TerrainSourceError.meshBudgetExceeded }
            remaining -= count * stride * prototype.parts.count
        }
        for (coordinate, rows) in storage.instanceCellSnapshot().sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let region = TerrainRegionCoordinate(x: floorDiv(coordinate.x, 4), z: floorDiv(coordinate.z, 4))
            guard residency.visible.contains(region) else { continue }
            let old = previousByCoordinate[coordinate] ?? []
            if !old.isEmpty, old.allSatisfy({ $0.value.inputID == rows.id }) {
                for (key, prepared) in old {
                    guard let prototype = residency.prototypes[key.prototype] else { throw TerrainSourceError.changedDuringBuild }
                    try charge(prototype, id: key.prototype, count: prepared.instanceCount)
                    cells[key] = prepared
                }
                continue
            }
            let groups = Dictionary(grouping: rows.records) { record in
                groupedRecordCount += 1
                return record.prototypeID
            }
            for prototypeID in groups.keys.sorted() {
                guard let reference = palette[prototypeID], let records = groups[prototypeID] else {
                    throw AssetError.message("A terrain placement references a missing mesh prototype")
                }
                let prototype: TerrainMeshPrototype
                if let prepared = residency.prototypes[prototypeID] {
                    prototype = prepared
                } else {
                    prototype = try await residency.cache.loadPrototype(reference)
                    residency.prototypes[prototypeID] = prototype
                }
                try charge(prototype, id: prototypeID, count: records.count)
                let key = TerrainInstanceCellKey(coordinate: coordinate, prototype: prototypeID)
                let placements = records.map { record in
                    Mesh3DInstance(
                        id: record.id,
                        transform: Transform3D(
                            translation: [
                                storage.origin.x + (Float(region.x * 256) + record.localPosition.x) * storage.spacing,
                                record.localPosition.y * storage.spacing,
                                storage.origin.y + (Float(region.z * 256) + record.localPosition.z) * storage.spacing,
                            ],
                            rotation: record.rotation,
                            scale: record.scale
                        ),
                        color: record.tint
                    )
                }
                let batches = try prototype.makeBatches(instances: placements, maximumExpandedBytes: min(maximumBytes, TerrainMeshPrototype.maximumExpandedBytes))
                let collisions = zip(records, placements).compactMap { record, placement -> TerrainCollisionPlacement? in
                    record.flags.contains(.collision) ? .init(record: record, transform: placement.transform) : nil
                }
                cells[key] = .init(inputID: rows.id, instanceCount: records.count, batches: batches, maximumDistance: reference.maximumDistance, collisionPlacements: collisions)
            }
        }
        // Only currently visible draw cells own imported prototypes. Old published resources remain
        // alive until atomic replacement; streamed-away prototypes are released with that generation.
        residency.prototypes = residency.prototypes.filter { charged.contains($0.key) }
        return (cells, residency, groupedRecordCount)
    }

    static func apply(_ cells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell], previous: [TerrainInstanceCellKey: TerrainSourceInstanceCell], owner: Entity, world: World)
        -> [TerrainInstanceCellKey: TerrainSourceInstanceCell] {
        var result: [TerrainInstanceCellKey: TerrainSourceInstanceCell] = [:]
        for key in previous.keys where cells[key] == nil {
            for id in previous[key]?.entities ?? [] { world.removeEntity(id, recursively: true) }
        }
        for key in cells.keys.sorted() {
            guard let prepared = cells[key] else { continue }
            let old = previous[key]
            if old?.prepared.id == prepared.id, old?.entities.allSatisfy({ world.getEntityByID($0)?.components[Mesh3DInstancesComponent.self] != nil }) == true {
                result[key] = old
                continue
            }
            var entities: [Entity.ID] = []
            for index in prepared.batches.indices {
                let existing = old.flatMap { $0.entities.indices.contains(index) ? world.getEntityByID($0.entities[index]) : nil }
                let child = existing ?? world.spawn("Terrain Instances \(key.coordinate.x),\(key.coordinate.z)/\(key.prototype)/\(index)")
                child.components[Mesh3DInstancesComponent.self] = prepared.batches[index]
                child.components[MeshLOD3DComponent.self] = .init(maximumDistance: prepared.maximumDistance)
                if existing == nil {
                    child.components[Transform.self] = Transform()
                    child.components[TransientEntity.self] = .init()
                    child.components[TerrainGenerated3D.self] = .init(owner: owner.id, sourceBacked: true)
                    owner.addChild(child)
                }
                entities.append(child.id)
            }
            for id in old?.entities.dropFirst(prepared.batches.count) ?? [][...] { world.removeEntity(id, recursively: true) }
            result[key] = .init(prepared: prepared, entities: entities)
        }
        return result
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}
