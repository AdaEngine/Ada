@_spi(AdaEngine) import AdaEngine
import Foundation

/// Restores existing immutable versions without replacing their resident scene.
@MainActor
enum EditorMeshTerrainHistory {
    struct Source {
        let editorID: String
        let pose: Transform
        let previousBinding: MeshTerrain3DBinding?
        let binding: MeshTerrain3DBinding?
        let identity: MeshTerrain3DIdentity?
    }

    struct Plan {
        let ownerEditorID: String
        let target: UUID
        let uri: String
        let sources: [Source]

        static func make(previous: EditorSceneModel, next: EditorSceneModel) throws -> Self? {
            guard previous.entities.map(\.id) == next.entities.map(\.id) else { return nil }
            let terrainKey = EditorBuiltInComponentType.terrain3DSource
            let identityKey = String(reflecting: MeshTerrain3DIdentity.self)
            let bindingKey = String(reflecting: MeshTerrain3DBinding.self)
            let owners = previous.entities.indices.filter {
                previous.entities[$0].components[terrainKey]?["source"] != next.entities[$0].components[terrainKey]?["source"]
            }
            guard owners.count == 1, let ownerIndex = owners.first,
                let before = previous.entities[ownerIndex].components[terrainKey],
                let after = next.entities[ownerIndex].components[terrainKey],
                let uri = after["source"]?.stringValue,
                let identity = try decode(MeshTerrain3DIdentity.self, previous.entities[ownerIndex].components[identityKey]) else { return nil }
            var normalized = next
            normalized.editor = previous.editor
            normalized.entities[ownerIndex].components[terrainKey] = before
            guard normalized.entities[ownerIndex] == previous.entities[ownerIndex] else { return nil }
            var sources: [Source] = []
            var joinedDescendants: Set<String> = []
            for index in previous.entities.indices where index != ownerIndex && previous.entities[index] != next.entities[index] {
                let old = previous.entities[index], new = next.entities[index]
                let previousBinding = try decode(MeshTerrain3DBinding.self, old.components[bindingKey])
                let binding = try decode(MeshTerrain3DBinding.self, new.components[bindingKey])
                let unbound = previousBinding == nil && binding == nil
                let transformChanged = old.components[EditorBuiltInComponentType.transform] != new.components[EditorBuiltInComponentType.transform]
                if unbound, !transformChanged || old.components[identityKey] != new.components[identityKey] { return nil }
                if transformChanged {
                    let subtree = Set(next.subtreeEntityIDs(rootedAt: new.id).dropFirst())
                    let descendants = try next.entities.filter { entity in
                        guard subtree.contains(entity.id), let child = try decode(MeshTerrain3DBinding.self, entity.components[bindingKey]) else { return false }
                        return child.enabled && child.target == identity.id
                    }
                    if unbound, descendants.isEmpty { return nil }
                    joinedDescendants.formUnion(descendants.map(\.id))
                }
                guard previousBinding.map({ $0.target == identity.id }) ?? true, binding.map({ $0.target == identity.id }) ?? true,
                    previousBinding?.modifier == nil || binding?.modifier == nil || previousBinding?.modifier == binding?.modifier else { return nil }
                for key in [EditorBuiltInComponentType.transform, identityKey, bindingKey] {
                    normalized.entities[index].components[key] = old.components[key]
                }
                guard normalized.entities[index] == old else { return nil }
                sources.append(.init(editorID: new.id, pose: try pose(in: new),
                    previousBinding: previousBinding, binding: binding, identity: try decode(MeshTerrain3DIdentity.self, new.components[identityKey])))
            }
            joinedDescendants.subtract(sources.map(\.editorID))
            for entity in next.entities where joinedDescendants.contains(entity.id) {
                let binding = try decode(MeshTerrain3DBinding.self, entity.components[bindingKey])
                sources.append(.init(editorID: entity.id, pose: try pose(in: entity), previousBinding: binding, binding: binding,
                    identity: try decode(MeshTerrain3DIdentity.self, entity.components[identityKey])))
            }
            guard normalized == previous, sources.count <= 512 else { return nil }
            return .init(ownerEditorID: previous.entities[ownerIndex].id, target: identity.id, uri: uri, sources: sources)
        }

        private static func pose(in entity: EditorSceneEntity) throws -> Transform {
            try entity.components[EditorBuiltInComponentType.transform].flatMap {
                try EditorComponentPayloadDecoder.decode(Transform.self, payload: $0) as? Transform
            } ?? .init()
        }

        private static func decode<Value: Decodable>(_ type: Value.Type, _ payload: EditorComponentPayload?) throws -> Value? {
            try payload.map { try JSONDecoder().decode(type, from: JSONEncoder().encode($0)) }
        }
    }

    @concurrent
    static func prepare(_ file: URL) async throws -> MeshTerrainDocumentAsset {
        let cache = try await TerrainRegionCache.open(manifestAt: file.path)
        let manifest = await cache.manifest
        guard let name = manifest.meshDocumentFileName else { throw EditorTerrainSourceAuthoring.Failure.unavailable }
        let asset = try await AssetsManager.loadFresh(MeshTerrainDocumentAsset.self, at: file.deletingLastPathComponent().appendingPathComponent(name).path)
        _ = try asset.acceptedCompiledProduct()
        try Task.checkCancellation()
        return asset
    }

    static func apply(_ plan: Plan, candidate: MeshTerrainDocumentAsset, file: URL, owner: Entity,
                      roots: [String: Entity], application: AppWorlds, isCurrent: () -> Bool) async throws {
        var request: MeshTerrain3DEdit?
        do {
            try await application.withWorldAccess {
                guard isCurrent(), application.main.getEntityByID(owner.id) === owner,
                    owner.components[MeshTerrain3DIdentity.self]?.id == plan.target,
                    let surface = owner.components[MeshTerrain3DSourceSurface.self], let inputKey = surface.asset.compiled?.inputKey,
                    surface.asset.document.id == candidate.document.id, owner.components[MeshTerrain3DEdit.self] == nil else {
                    throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                }
                if owner.components[Terrain3DSource.self]?.source == file.path, inputKey == candidate.compiled?.inputKey,
                    plan.sources.allSatisfy({ change in
                        guard let root = roots[change.editorID], application.main.getEntityByID(root.id) === root else { return false }
                        return root.components[Transform.self] == change.pose && root.components[MeshTerrain3DBinding.self] == change.binding
                            && root.components[MeshTerrain3DIdentity.self] == change.identity && root.components[MeshTerrain3DProposedPose.self] == nil
                            && (change.binding?.enabled != true || root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
                    }) { return }
                let ownership = try MeshTerrain3DOwnership.capture(of: owner, in: application.main)
                var draws = Dictionary(uniqueKeysWithValues: ownership.draws.map { ($0.entity, $0) })
                var collisions = Set(ownership.collisions)
                var poses: [MeshTerrainSourceTransform] = [], updates: [MeshTerrainBindingUpdate] = []
                for change in plan.sources {
                    guard let root = roots[change.editorID], application.main.getEntityByID(root.id) === root else {
                        throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                    }
                    let residentBinding = root.components[MeshTerrain3DBinding.self]
                    guard residentBinding == change.previousBinding || residentBinding == change.binding else {
                        throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                    }
                    poses.append(.init(entity: root.id, pose: change.pose))
                    if change.previousBinding == nil, change.binding == nil { continue }
                    if let old = residentBinding {
                        let previous = try MeshTerrainSourceCapture.capture(root, parts: old.parts)
                        for draw in previous.drawReplacements { draws.removeValue(forKey: draw.entity) }
                        collisions.subtract(try MeshTerrainSourceCapture.collisionSources(root, parts: old.parts, in: application.main))
                    }
                    var selected: [MeshTerrainDrawReplacement] = [], selectedCollisions: Set<Entity.ID> = []
                    if let binding = change.binding, binding.enabled, binding.operation == .union {
                        selected = try MeshTerrainSourceCapture.capture(root, parts: binding.parts).drawReplacements
                        for draw in selected { draws[draw.entity] = draw }
                        if owner.components[Terrain3DSource.self]?.generatesCollision == true, application.main.physicsWorld3D != nil {
                            selectedCollisions = Set(try MeshTerrainSourceCapture.collisionSources(root, parts: binding.parts, in: application.main))
                            collisions.formUnion(selectedCollisions)
                        }
                    }
                    guard let modifier = change.binding?.modifier ?? change.previousBinding?.modifier else {
                        throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                    }
                    updates.append(.init(entity: root.id, modifier: modifier, identity: change.identity, binding: change.binding,
                        draws: Set(selected.map(\.entity)), collisions: selectedCollisions))
                }
                let edit = MeshTerrain3DEdit(expectedInputKey: inputKey, candidate: candidate, sourceTransforms: poses,
                    drawReplacements: draws.values.sorted { $0.entity < $1.entity }, collisionReplacements: collisions.sorted(),
                    adoptionManifest: file.path, bindingUpdates: updates)
                request = edit
                owner.components[MeshTerrain3DEdit.self] = edit
            }
            guard let submitted = request else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                let done = try await application.withWorldAccess {
                    guard isCurrent(), application.main.getEntityByID(owner.id) === owner else { throw CancellationError() }
                    guard let status = owner.components[MeshTerrain3DEditStatus.self], status.id == submitted.id else { return false }
                    switch status.phase {
                    case .pending: return false
                    case .failed: throw EditorTerrainSourceAuthoring.Failure.failed(status.error ?? "Mesh Terrain could not be updated.")
                    case .cancelled: throw CancellationError()
                    case .applied:
                        guard owner.components[Terrain3DSource.self]?.source == file.path,
                            owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == candidate.compiled?.inputKey else {
                            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                        }
                        return true
                    }
                }
                if done { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw EditorTerrainSourceAuthoring.Failure.timedOut
        } catch {
            await Task { @MainActor in
                try? await application.withWorldAccess {
                    if application.main.getEntityByID(owner.id) === owner, owner.components[MeshTerrain3DEdit.self]?.id == request?.id {
                        owner.components.remove(MeshTerrain3DEdit.self)
                    }
                }
            }.value
            throw error
        }
    }
}
