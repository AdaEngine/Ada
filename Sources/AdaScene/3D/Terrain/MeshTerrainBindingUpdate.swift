import AdaECS
import AdaGeometry
@_spi(Internal) import AdaPhysics
import AdaTransform
import Foundation
import Math

/// A scene binding and its source ownership to publish with a prepared terrain generation.
/// Nil identity/binding removes that authored component, supporting exact cancellation.
public struct MeshTerrainBindingUpdate: Sendable {
    public let entity: Entity.ID
    public let modifier: UUID
    public let identity: MeshTerrain3DIdentity?
    public let binding: MeshTerrain3DBinding?
    public let draws: Set<Entity.ID>
    public let collisions: Set<Entity.ID>

    public init(entity: Entity.ID, modifier: UUID, identity: MeshTerrain3DIdentity?, binding: MeshTerrain3DBinding?,
                draws: Set<Entity.ID> = [], collisions: Set<Entity.ID> = []) {
        self.entity = entity; self.modifier = modifier; self.identity = identity; self.binding = binding
        self.draws = draws; self.collisions = collisions
    }
}

struct MeshTerrainEditPublication {
    let poses: [Transform]
    let bindings: [Entity.ID: MeshTerrainBindingState]
}

enum MeshTerrainBindingUpdates {
    static func prepare(_ request: MeshTerrain3DEdit, owner: Entity, world: World) throws -> [Entity.ID: MeshTerrainBindingState] {
        guard request.bindingUpdates.count <= 512,
            Set(request.bindingUpdates.map(\.entity)).count == request.bindingUpdates.count,
            Set(request.bindingUpdates.map(\.modifier)).count == request.bindingUpdates.count else { throw TriangleGeometryError.budgetExceeded }
        let poses = try request.sourceTransforms.reduce(into: [Entity.ID: Transform]()) { $0[$1.entity] = try $1.resolvedPose() }
        var result: [Entity.ID: MeshTerrainBindingState] = [:]
        for update in request.bindingUpdates {
            guard update.entity != owner.id, let source = world.getEntityByID(update.entity),
                source.components[MeshTerrain3DBinding.self].map({ $0.modifier == update.modifier && $0.target == owner.components[MeshTerrain3DIdentity.self]?.id }) ?? true else {
                throw TriangleGeometryError.invalidInput
            }
            guard let binding = update.binding else {
                guard !request.candidate.document.modifiers.contains(where: { $0.id == update.modifier && $0.enabled }),
                    update.draws.isEmpty, update.collisions.isEmpty else { throw TriangleGeometryError.invalidInput }
                continue
            }
            guard let identity = update.identity, binding.modifier == update.modifier,
                binding.target == owner.components[MeshTerrain3DIdentity.self]?.id,
                let modifier = request.candidate.document.modifiers.first(where: { $0.id == update.modifier }),
                modifier.entityID == identity.id, modifier.sourceID == binding.sourceID, modifier.operation == binding.operation,
                modifier.enabled == binding.enabled, modifier.contactWidth == binding.contactWidth else { throw TriangleGeometryError.invalidInput }
            let parts = binding.enabled ? try MeshTerrainSourceCapture.collect(source, selections: binding.parts) : []
            let capturedDraws = binding.enabled && binding.operation == .union ? Set(parts.map(\.entity)) : []
            let ownedDraws = Set(request.drawReplacements?.map(\.entity) ?? Array(owner.components[TerrainSourceState.self]?.meshMaskedSources ?? []))
            let ownedCollisions = Set(request.collisionReplacements ?? Array(owner.components[TerrainSourceState.self]?.meshCollisionSources ?? []))
            guard update.draws == capturedDraws, update.draws.isSubset(of: ownedDraws), update.collisions.isSubset(of: ownedCollisions) else {
                throw TriangleGeometryError.invalidInput
            }
            let pose = poses[source.id] ?? source.components[Transform.self] ?? .init()
            let relative = Terrain3DSourceSystem.worldMatrix(owner).inverse * Terrain3DSourceSystem.worldMatrix(source, overriding: poses)
            for column in 0..<4 { for row in 0..<4 {
                guard abs(relative[column, row] - modifier.transform[column, row]) <= 0.0001 * max(1, abs(modifier.transform[column, row])) else {
                    throw TerrainSourceError.changedDuringBuild
                }
            } }
            let collision = owner.components[Terrain3DSource.self]?.generatesCollision == true && world.getResource(Physics3DWorldHolder.self) != nil
            result[source.id] = .init(signature: .init(binding: binding, relative: relative, localPose: pose,
                parts: MeshTerrainSourceCapture.generations(parts), collision: collision), editID: nil, proposalID: nil,
                masked: update.draws, collisions: update.collisions, acceptedPose: pose, acceptedDocumentKey: request.candidate.compiled?.inputKey)
        }
        return result
    }

    static func publish(_ request: MeshTerrain3DEdit, prepared: [Entity.ID: MeshTerrainBindingState], owner: Entity, world: World) {
        var changes: [MeshTerrainBindingOwnership] = []
        for update in request.bindingUpdates {
            guard let source = world.getEntityByID(update.entity) else { continue }
            if let identity = update.identity { source.components[MeshTerrain3DIdentity.self] = identity }
            else { source.components.remove(MeshTerrain3DIdentity.self) }
            if let binding = update.binding, let state = prepared[update.entity] {
                source.components[MeshTerrain3DBinding.self] = binding
                source.components[MeshTerrainBindingState.self] = state
                source.components[MeshTerrain3DBindingStatus.self] = .init(phase: .applied, error: nil)
                changes.append(.init(modifier: update.modifier, source: source.id, draws: update.draws, collisions: update.collisions))
            } else {
                source.components.remove(MeshTerrain3DBinding.self)
                source.components.remove(MeshTerrainBindingState.self)
                source.components.remove(MeshTerrain3DBindingStatus.self)
                changes.append(.init(modifier: update.modifier, source: nil, draws: [], collisions: []))
            }
            source.components.remove(MeshTerrain3DProposedPose.self)
        }
        MeshTerrainBindingLifecycle.publish(changes, owner: owner, world: world)
    }
}
