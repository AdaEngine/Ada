import AdaECS
import AdaGeometry
@_spi(Internal) import AdaRender
import AdaUtils

/// A stable part address inside the retained source mesh.
public struct MeshTerrainSourcePart: Codable, Hashable, Sendable {
    public let model: Int
    public let part: Int
    public init(model: Int, part: Int) { self.model = model; self.part = part }
}

/// Derived render ownership. An empty part set replaces the complete source draw.
/// Authored mesh/material/visibility components remain available to the editor.
public struct MeshTerrain3DSourceMask: Component, Sendable {
    public let owner: Entity.ID
    public let parts: Set<MeshTerrainSourcePart>
    let revision = RID()
    public init(owner: Entity.ID, parts: Set<MeshTerrainSourcePart> = []) { self.owner = owner; self.parts = parts }
}

public struct MeshTerrainDrawReplacement: Sendable {
    public let entity: Entity.ID
    public let parts: Set<MeshTerrainSourcePart>
    public init(entity: Entity.ID, parts: Set<MeshTerrainSourcePart> = []) { self.entity = entity; self.parts = parts }
}

/// Immutable source ownership captured at a tooling world safe point for cancellation and history.
public struct MeshTerrain3DOwnership: Sendable {
    public let draws: [MeshTerrainDrawReplacement]
    public let collisions: [Entity.ID]

    public static func capture(of owner: Entity, in world: World) throws -> Self {
        guard world.getEntityByID(owner.id) === owner, let state = owner.components[TerrainSourceState.self], state.meshAsset != nil else {
            throw TriangleGeometryError.invalidInput
        }
        return .init(draws: state.meshMaskedSources.sorted().compactMap { id in
            guard let mask = world.getEntityByID(id)?.components[MeshTerrain3DSourceMask.self], mask.owner == owner.id else { return nil }
            return .init(entity: id, parts: mask.parts)
        }, collisions: state.meshCollisionSources.sorted())
    }

    /// Returns ownership from the accepted binding, even if the source mesh is no longer loaded.
    public static func capture(of owner: Entity, for source: Entity, in world: World) throws -> Self {
        guard let binding = source.components[MeshTerrain3DBinding.self],
            binding.target == owner.components[MeshTerrain3DIdentity.self]?.id,
            world.getEntityByID(source.id) === source else { throw TriangleGeometryError.invalidInput }
        let accepted = try capture(of: owner, in: world)
        guard let link = owner.components[TerrainSourceState.self]?.meshBindings[binding.modifier] else {
            return .init(draws: [], collisions: [])
        }
        guard link.source == source.id else { throw TriangleGeometryError.invalidInput }
        return .init(draws: accepted.draws.filter { link.draws.contains($0.entity) }, collisions: accepted.collisions.filter { link.collisions.contains($0) })
    }
}

enum MeshTerrainDrawMasking {
    static func fullyMasked(_ mesh: Mesh, by mask: MeshTerrain3DSourceMask) -> Bool {
        if mask.parts.isEmpty { return true }
        return mesh.models.enumerated().allSatisfy { modelIndex, model in
            model.parts.enumerated().allSatisfy { partIndex, part in
                part.indexCount == 0 || mask.parts.contains(.init(model: modelIndex, part: partIndex))
            }
        }
    }

    /// Every render consumer receives the same derived source, including shadows
    /// and tracing. Original components and buffer objects are never modified.
    static func applying(_ mask: MeshTerrain3DSourceMask, to mesh: Mesh) -> Mesh {
        let models = mesh.models.enumerated().map { modelIndex, model in
            var result = model
            for index in result.parts.indices where mask.parts.contains(.init(model: modelIndex, part: index)) {
                result.parts[index].indexCount = 0
            }
            return result
        }
        // Partial source LODs require an explicit compatible part mapping. The
        // source's full-detail visible parts remain a correct bounded fallback.
        return Mesh(models: models)
    }

}
