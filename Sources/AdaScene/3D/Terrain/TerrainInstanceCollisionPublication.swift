import AdaECS
@_spi(Internal) import AdaPhysics
import Math

extension Terrain3DSourceSystem {
    static func advanceInstanceCollisions(_ publication: inout TerrainSourcePublication, source: Terrain3DSource, previous: TerrainSourceState?, world: World) throws -> Bool {
        guard publication.collision else {
            return true
        }
        let selected = publication.product.build.instanceColliders
        if publication.instanceCoordinates == nil {
            publication.instanceCoordinates = selected.keys.filter { id in
                guard let old = previous?.instanceColliders[id], let prepared = selected[id], old.prepared.id == prepared.id,
                    previous?.matrix == publication.matrix,
                    world.getEntityByID(old.entity)?.components[PhysicsBody3DComponent.self] != nil
                else { return true }
                return false
            }.sorted()
        }
        let coordinates = publication.instanceCoordinates ?? []
        let end = min(coordinates.count, publication.instanceCursor + source.instanceCollision.maximumUpdatesPerFrame)
        for index in publication.instanceCursor..<end {
            let id = coordinates[index]
            guard let prepared = selected[id] else { throw TerrainSourceError.changedDuringBuild }
            publication.instanceShapes[id] = try makeShape(
                prepared.descriptor,
                matrix: publication.matrix,
                metrics: world.getResource(Physics3DWorldHolder.self)?.world.collisionPreparationMetrics
            )
        }
        publication.instanceCursor = end
        return end == coordinates.count
    }

    static func validateInstanceColliders(
        _ selected: [UInt64: TerrainPreparedInstanceCollider],
        previous: [UInt64: TerrainSourceInstanceCollider],
        shapes: [UInt64: Shape3DResource],
        world: World
    ) throws {
        // All native work is complete before this synchronous publication starts.
        for (id, prepared) in selected where shapes[id] == nil {
            guard let old = previous[id], old.prepared.id == prepared.id,
                world.getEntityByID(old.entity)?.components[PhysicsBody3DComponent.self] != nil
            else { throw TerrainSourceError.changedDuringBuild }
        }
    }

    static func applyInstanceColliders(
        _ selected: [UInt64: TerrainPreparedInstanceCollider],
        previous: [UInt64: TerrainSourceInstanceCollider],
        shapes: [UInt64: Shape3DResource],
        owner: Entity,
        world: World
    ) -> [UInt64: TerrainSourceInstanceCollider] {
        var result: [UInt64: TerrainSourceInstanceCollider] = [:]
        for (id, old) in previous where selected[id] == nil || shapes[id] != nil { world.removeEntity(old.entity, recursively: true) }
        for (id, prepared) in selected {
            if let shape = shapes[id] {
                let entity = makeCollider(shape, owner: owner, world: world, name: "Terrain Prop Collision \(id)")
                result[id] = .init(prepared: prepared, entity: entity)
            } else { result[id] = previous[id] }
        }
        return result
    }
}
