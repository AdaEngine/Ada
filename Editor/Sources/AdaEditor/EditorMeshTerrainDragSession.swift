@_spi(AdaEngine) import AdaEngine
import Foundation

/// Retains the pre-gesture generation before the first provisional world pose.
@MainActor
final class EditorMeshTerrainDragSession {
    struct Snapshot: Sendable {
        let source: Terrain3DSource
        let asset: MeshTerrainDocumentAsset
        let ownership: MeshTerrain3DOwnership
        let binding: MeshTerrain3DBinding
        let identity: MeshTerrain3DIdentity
        let draws: Set<Entity.ID>
        let collisions: Set<Entity.ID>
    }

    let sourceEditorID: String
    let targetEditorID: String
    let source: Entity
    let owner: Entity
    let initialPose: Transform
    let initialPayload: EditorComponentPayload
    let initialContent: String
    let generation: UUID
    let captured: Task<Snapshot, any Error>
    let ready: Task<Void, any Error>

    init(sourceEditorID: String, targetEditorID: String, source: Entity, owner: Entity, initialPose: Transform,
         initialPayload: EditorComponentPayload, initialContent: String, generation: UUID, application: AppWorlds) {
        self.sourceEditorID = sourceEditorID; self.targetEditorID = targetEditorID; self.source = source; self.owner = owner
        self.initialPose = initialPose; self.initialPayload = initialPayload; self.initialContent = initialContent; self.generation = generation
        let captured = Task<Snapshot, any Error> { @MainActor in
            try await application.withWorldAccess {
                guard application.main.getEntityByID(source.id) === source, application.main.getEntityByID(owner.id) === owner,
                    let settings = owner.components[Terrain3DSource.self], let asset = owner.components[MeshTerrain3DSourceSurface.self]?.asset,
                    let binding = source.components[MeshTerrain3DBinding.self], binding.enabled,
                    binding.target == owner.components[MeshTerrain3DIdentity.self]?.id,
                    let identity = source.components[MeshTerrain3DIdentity.self], source.components[Transform.self] == initialPose,
                    source.components[MeshTerrain3DProposedPose.self] == nil, owner.components[MeshTerrain3DEdit.self] == nil else {
                    throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                }
                let ownership = try MeshTerrain3DOwnership.capture(of: owner, in: application.main)
                let parts = try MeshTerrainSourceCapture.capture(source, parts: binding.parts)
                let possibleCollisions = try MeshTerrainSourceCapture.collisionSources(source, parts: binding.parts, in: application.main)
                return .init(source: settings, asset: asset, ownership: ownership, binding: binding, identity: identity,
                    draws: Set(parts.drawReplacements.map(\.entity)).intersection(ownership.draws.map(\.entity)),
                    collisions: Set(possibleCollisions).intersection(ownership.collisions))
            }
        }
        self.captured = captured
        self.ready = Task { _ = try await captured.value }
    }

    func bindingUpdate(_ snapshot: Snapshot) -> MeshTerrainBindingUpdate {
        .init(entity: source.id, modifier: snapshot.binding.modifier, identity: snapshot.identity, binding: snapshot.binding,
            draws: snapshot.draws, collisions: snapshot.collisions)
    }
}
