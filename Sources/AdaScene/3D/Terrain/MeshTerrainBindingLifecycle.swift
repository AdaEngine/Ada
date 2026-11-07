import AdaAssets
import AdaECS
import AdaGeometry
import Foundation

/// Runtime ownership follows the accepted generation, never a provisional scene edit.
struct MeshTerrainBindingOwnership: Sendable {
    let modifier: UUID
    let source: Entity.ID?
    let draws: Set<Entity.ID>
    let collisions: Set<Entity.ID>
}

enum MeshTerrainBindingLifecycle {
    static func live(_ link: MeshTerrainBindingOwnership, owner: Entity, world: World) -> Bool {
        guard let id = link.source, let source = world.getEntityByID(id), let binding = source.components[MeshTerrain3DBinding.self] else { return false }
        return binding.modifier == link.modifier && binding.target == owner.components[MeshTerrain3DIdentity.self]?.id
    }

    static func reconcile(_ owner: Entity, world: World) throws {
        guard let state = owner.components[TerrainSourceState.self], let asset = state.meshAsset,
            owner.components[Terrain3DSource.self] != nil else { return }
        let stale = state.meshBindings.values.filter { !live($0, owner: owner, world: world) }
        guard !stale.isEmpty else { return }
        let removed = Set(stale.map(\.modifier))
        if let busy = owner.components[MeshTerrain3DEdit.self] {
            let detaching = Set(busy.bindingChanges.filter { $0.source == nil }.map(\.modifier))
            if detaching == removed { return }
            guard !busy.bindingChanges.isEmpty, busy.bindingChanges.allSatisfy({ removed.contains($0.modifier) }) else { return }
        }
        var document = asset.document
        document.modifiers.removeAll { removed.contains($0.id) }
        let draws = stale.reduce(into: Set<Entity.ID>()) { $0.formUnion($1.draws) }
        let collisions = stale.reduce(into: Set<Entity.ID>()) { $0.formUnion($1.collisions) }
        let replacements = state.meshMaskedSources.subtracting(draws).compactMap { id -> MeshTerrainDrawReplacement? in
            guard let mask = world.getEntityByID(id)?.components[MeshTerrain3DSourceMask.self] else { return nil }
            return .init(entity: id, parts: mask.parts)
        }
        let candidate = MeshTerrainDocumentAsset(document: document, populationRules: asset.populationRules,
            manualPlacements: asset.manualPlacements, populationOverrides: asset.populationOverrides)
        var edit = MeshTerrain3DEdit(expectedInputKey: try asset.authoringKey(), candidate: candidate, drawReplacements: replacements,
            collisionReplacements: state.meshCollisionSources.subtracting(collisions).sorted())
        edit.bindingChanges = stale.map { .init(modifier: $0.modifier, source: nil, draws: [], collisions: []) }
        owner.components[MeshTerrain3DEdit.self] = edit
    }

    static func validate(_ changes: [MeshTerrainBindingOwnership], owner: Entity, world: World) throws {
        for change in changes {
            if change.source != nil {
                guard live(change, owner: owner, world: world) else { throw TerrainSourceError.changedDuringBuild }
            } else if let old = owner.components[TerrainSourceState.self]?.meshBindings[change.modifier] {
                guard !live(old, owner: owner, world: world) else { throw TerrainSourceError.changedDuringBuild }
            }
        }
    }

    static func publish(_ changes: [MeshTerrainBindingOwnership], owner: Entity, world: World) {
        guard !changes.isEmpty, var state = owner.components[TerrainSourceState.self] else { return }
        for change in changes {
            if change.source != nil { state.meshBindings[change.modifier] = change }
            else if let old = state.meshBindings.removeValue(forKey: change.modifier), let id = old.source, let source = world.getEntityByID(id),
                source.components[MeshTerrainBindingState.self]?.signature.binding.target == owner.components[MeshTerrain3DIdentity.self]?.id {
                source.components.remove(MeshTerrainBindingState.self)
                source.components.remove(MeshTerrain3DBindingStatus.self)
            }
        }
        owner.components[TerrainSourceState.self] = state
    }

    /// A retarget waits for its own previous accepted ownership to be released.
    /// Overlapping ownership by another bound root is an unsupported input.
    static func waitsForPreviousOwner(source: Entity, target: Entity, parts: [MeshTerrainCapturedPart], world: World) throws -> Bool {
        var owners: Set<Entity.ID> = []
        for part in parts {
            if let mask = world.getEntityByID(part.entity)?.components[MeshTerrain3DSourceMask.self], mask.owner != target.id { owners.insert(mask.owner) }
        }
        if let backup = source.components[MeshTerrainSourceCollisionBackup.self], backup.owner != target.id { owners.insert(backup.owner) }
        for id in owners {
            guard let owner = world.getEntityByID(id), owner.components[TerrainSourceState.self]?.meshBindings.values.contains(where: { $0.source == source.id }) == true else {
                throw TriangleGeometryError.invalidInput
            }
        }
        return !owners.isEmpty
    }
}
