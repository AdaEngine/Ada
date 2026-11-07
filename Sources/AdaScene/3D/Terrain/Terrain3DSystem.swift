import AdaECS
@_spi(Internal) import AdaPhysics
@_spi(Internal) import AdaRender
import AdaTransform
import Math

private struct TerrainTileRuntime {
    var entity: Entity.ID
    var collider: Entity.ID?
    var descriptor: MeshDescriptor
}

private struct Terrain3DRuntimeState: Component {
    var source: Terrain3D
    var matrix: Transform3D
    var material: PBRMaterial
    var tiles: [TerrainTileCoordinate: TerrainTileRuntime]
}

/// Maintains independently replaceable terrain tiles and matching static triangle collision.
@PlainSystem
public struct Terrain3DSystem {
    private static let cellCount = Terrain3D.defaultTileCellCount

    @Query<Entity, Terrain3D> private var terrains
    @Query<Entity, Terrain3DRuntimeState> private var builtTerrains
    @Commands private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        terrains.forEach { entity, terrain in
            let matrix = Self.worldMatrix(entity)
            let state = entity.components[Terrain3DRuntimeState.self]
            guard state?.source != terrain || state?.matrix != matrix else {
                return
            }
            let id = entity.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3D.self] == terrain,
                    let engine = unsafe RenderEngine.shared, (try? terrain.validate()) != nil
                else { return }
                Self.apply(terrain, matrix: matrix, to: owner, in: world, device: engine.renderDevice)
            }
        }
        builtTerrains.forEach { entity, state in
            guard entity.components[Terrain3D.self] == nil else {
                return
            }
            let id = entity.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3D.self] == nil else {
                    return
                }
                for tile in state.tiles.values { Self.remove(tile, in: world) }
                owner.components.remove(Terrain3DRuntimeState.self)
            }
        }
    }

    private static func apply(_ terrain: Terrain3D, matrix: Transform3D, to owner: Entity, in world: World, device: RenderDevice) {
        let previous = owner.components[Terrain3DRuntimeState.self]
        var state = previous ?? Terrain3DRuntimeState(source: terrain, matrix: matrix, material: PBRMaterial(), tiles: [:])
        if previous == nil || previous?.source.color != terrain.color {
            state.material.baseColorFactor = terrain.color
            state.material.roughnessFactor = 0.95
        }
        let layoutChanged = previous?.source.resolution != terrain.resolution || previous?.source.size != terrain.size
        let heightsChanged = layoutChanged || previous?.source.heights != terrain.heights
        let collisionEnabled = terrain.generatesCollision && world.getResource(Physics3DWorldHolder.self) != nil
        let side = (terrain.resolution - 2) / cellCount + 1
        var desired: Set<TerrainTileCoordinate> = []
        for z in 0..<side {
            for x in 0..<side {
                let coordinate = TerrainTileCoordinate(x: x, z: z)
                desired.insert(coordinate)
                let oldTile = state.tiles[coordinate]
                let changed =
                    layoutChanged
                    || (heightsChanged
                        && previous.map {
                            changedSamples(at: coordinate, from: $0.source, to: terrain)
                        } == true)
                let needsMesh = changed || oldTile.flatMap { world.getEntityByID($0.entity) } == nil
                var tile = oldTile
                if needsMesh, let meshTile = try? terrain.meshTile(at: coordinate) {
                    let existing = oldTile.flatMap { world.getEntityByID($0.entity) }
                    let entity = existing ?? world.spawn("Terrain Tile \(x),\(z)")
                    entity.components[Mesh3DComponent.self] = Mesh3DComponent(
                        mesh: Mesh.generate(from: [meshTile.descriptor], renderDevice: device),
                        materials: [state.material]
                    )
                    if existing == nil {
                        entity.components[TransientEntity.self] = .init()
                        entity.components[TerrainGenerated3D.self] = .init(owner: owner.id, sourceBacked: false)
                        entity.components[Transform.self] = Transform()
                        entity.components[TerrainTile3DComponent.self] = TerrainTile3DComponent(coordinate: coordinate)
                        owner.addChild(entity)
                    }
                    tile = TerrainTileRuntime(entity: entity.id, collider: oldTile?.collider, descriptor: meshTile.descriptor)
                }
                guard var tile else { continue }
                if needsMesh || previous?.matrix != matrix || previous?.source.generatesCollision != terrain.generatesCollision
                    || (collisionEnabled && tile.collider == nil) {
                    if let collider = tile.collider { world.removeEntity(collider, recursively: true) }
                    tile.collider = collisionEnabled ? makeCollider(tile.descriptor, matrix: matrix, owner: owner, world: world) : nil
                }
                state.tiles[coordinate] = tile
            }
        }
        for coordinate in state.tiles.keys.filter({ !desired.contains($0) }) {
            if let tile = state.tiles.removeValue(forKey: coordinate) { remove(tile, in: world) }
        }
        // Generated geometry belongs to the tile children, not the authored owner.
        owner.components.remove(Mesh3DComponent.self)
        state.source = terrain
        state.matrix = matrix
        owner.components[Terrain3DRuntimeState.self] = state
    }

    private static func changedSamples(at coordinate: TerrainTileCoordinate, from previous: Terrain3D, to terrain: Terrain3D) -> Bool {
        // Include the normal's one-sample halo; an edge edit also invalidates its neighbor.
        let minX = max(0, coordinate.x * cellCount - 1), maxX = min(terrain.resolution - 1, (coordinate.x + 1) * cellCount + 1)
        let minZ = max(0, coordinate.z * cellCount - 1), maxZ = min(terrain.resolution - 1, (coordinate.z + 1) * cellCount + 1)
        for z in minZ...maxZ {
            let range = (z * terrain.resolution + minX)...(z * terrain.resolution + maxX)
            if previous.heights[range] != terrain.heights[range] {
                return true
            }
        }
        return false
    }

    private static func makeCollider(_ descriptor: MeshDescriptor, matrix: Transform3D, owner: Entity, world: World) -> Entity.ID? {
        var indices = descriptor.indicies
        if matrix.determinant < 0 {
            for index in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(index + 1, index + 2) }
        }
        guard
            let shape = try? Shape3DResource.generateTriangleMesh(
                vertices: descriptor.positions.elements.map { (matrix * Vector4($0, 1)).xyz },
                indices: indices
            )
        else { return nil }
        // Physics bodies consume world transforms. Bake parent scale and rotation into each tile's vertices.
        let collider = world.spawn("Terrain Collision")
        collider.components[TransientEntity.self] = .init()
        collider.components[TerrainGenerated3D.self] = .init(owner: owner.id, sourceBacked: false)
        collider.components[Transform.self] = Transform()
        collider.components[PhysicsBody3DComponent.self] = PhysicsBody3DComponent(shapes: [shape], mode: .static)
        owner.addChild(collider)
        if let physics = world.getResource(Physics3DWorldHolder.self) {
            Physics3DSyncSystem.initializeImmediately(collider, in: physics.world)
        }
        return collider.id
    }

    private static func remove(_ tile: TerrainTileRuntime, in world: World) {
        world.removeEntity(tile.entity, recursively: true)
        if let collider = tile.collider { world.removeEntity(collider, recursively: true) }
    }

    private static func worldMatrix(_ entity: Entity) -> Transform3D {
        var matrix = entity.components[Transform.self]?.matrix ?? .identity
        var parentID = entity.components[RelationshipComponent.self]?.parent
        var visited: Set<Entity.ID> = [entity.id]
        while let id = parentID, visited.insert(id).inserted, let parent = entity.world?.getEntityByID(id) {
            matrix = (parent.components[Transform.self]?.matrix ?? .identity) * matrix
            parentID = parent.components[RelationshipComponent.self]?.parent
        }
        return matrix
    }
}
