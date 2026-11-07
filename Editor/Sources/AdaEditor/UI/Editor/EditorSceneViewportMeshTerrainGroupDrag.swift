@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorMeshTerrainGroupDrag {
    let editorID: String
    let entities: [String]
    let initialPose: Transform
    let initialPayload: EditorComponentPayload
    let initialContent: String
    let generation: UUID
}

extension EditorSceneViewportModel {
    func meshTerrainBoundDescendants(of editorID: String, in model: EditorSceneModel? = nil) -> [String] {
        guard let model = model ?? sceneModel else { return [] }
        let descendants = Set(model.subtreeEntityIDs(rootedAt: editorID).dropFirst())
        let key = String(reflecting: MeshTerrain3DBinding.self)
        return model.entities.compactMap { entity in
            guard descendants.contains(entity.id), let binding = entity.components[key], binding["enabled"] != .bool(false) else { return nil }
            return entity.id
        }
    }

    func beginMeshTerrainGroupDrag(editorID: String, descendants: [String], payload: EditorComponentPayload, pose: Transform) -> Bool {
        guard !terrainEditing.isSourceBusy, TriangleMeshBoolean.isAvailable, terrainSourceContext != nil else { return false }
        let generation = UUID()
        terrainEditing.sourceGeneration = generation
        terrainEditing.isSourceBusy = true
        terrainEditing.sourceFailure = nil
        terrainEditing.sourceStatus = "Moving joined mesh…"
        terrainEditing.meshGroupDrag = .init(editorID: editorID, entities: [editorID] + descendants, initialPose: pose,
            initialPayload: payload, initialContent: sceneContent, generation: generation)
        return true
    }

    func finishMeshTerrainGroupDrag(_ group: EditorMeshTerrainGroupDrag, cancelled: Bool) {
        guard let context = terrainSourceContext, let expected = sceneModel else { return }
        let payload = expected.entities.first { $0.id == group.editorID }?.components[EditorBuiltInComponentType.transform]
        terrainEditing.sourceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.terrainEditing.meshGroupDrag?.generation == group.generation { self.terrainEditing.meshGroupDrag = nil }
                self.finishSourceTerrainTask(generation: group.generation)
                if let model = self.sceneModel {
                    self.onSelectionChanged?(self.selectedEntityViewModel(editorID: self.selectedEditorID, model: model))
                }
            }
            do {
                if cancelled { throw CancellationError() }
                guard let payload, let pose = try EditorComponentPayloadDecoder.decode(Transform.self, payload: payload) as? Transform else {
                    throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                }
                if pose == group.initialPose { return }
                let (input, targetID) = try await context.application.withWorldAccess {
                    try self.groupTerrainTransaction(group, pose: pose, world: context.application.main)
                }
                try await EditorMeshTerrainTransaction.run(input, application: context.application,
                    isCurrent: { self.terrainEditing.sourceGeneration == group.generation && self.matchesMeshDragModel(expected) },
                    onProgress: { self.terrainEditing.sourceStatus = $0 },
                    commit: { file in
                        try self.commitMeshTerrainGroupFile(file, targetID: targetID, assetsRoot: context.assetsRoot, expected: expected)
                    })
            } catch {
                if self.sceneContent == group.initialContent, self.matchesMeshDragModel(expected),
                    let index = self.sceneModel?.entities.firstIndex(where: { $0.id == group.editorID }) {
                    self.sceneModel?.entities[index].components[EditorBuiltInComponentType.transform] = group.initialPayload
                    self.onTransformChanged?(group.editorID, group.initialPayload)
                }
                if !(error is CancellationError), self.terrainEditing.sourceGeneration == group.generation {
                    self.terrainEditing.sourceStatus = "Mesh Terrain could not be updated."
                    self.terrainEditing.sourceFailure = error.localizedDescription
                }
            }
        }
    }

    private func groupTerrainTransaction(_ group: EditorMeshTerrainGroupDrag, pose: Transform, world: World) throws
        -> (EditorMeshTerrainTransaction.Input, String) {
        guard let groupEntity = runtimeEntity(for: group.editorID), world.getEntityByID(groupEntity.id) === groupEntity,
            groupEntity.components[Transform.self] == group.initialPose else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
        var bound = try group.entities.dropFirst().map { id -> (Entity, MeshTerrain3DBinding) in
            guard let entity = runtimeEntity(for: id), let binding = entity.components[MeshTerrain3DBinding.self], binding.enabled else {
                throw EditorTerrainSourceAuthoring.Failure.sourceChanged
            }
            return (entity, binding)
        }
        if let binding = groupEntity.components[MeshTerrain3DBinding.self], binding.enabled { bound.insert((groupEntity, binding), at: 0) }
        guard let target = bound.first?.1.target, bound.allSatisfy({ $0.1.target == target }) else {
            throw EditorTerrainSourceAuthoring.Failure.failed("This group must have a single Mesh Terrain target.")
        }
        let targets = (sceneModel?.entities ?? []).compactMap { row -> (String, Entity)? in
            guard let entity = runtimeEntity(for: row.id), entity.components[MeshTerrain3DIdentity.self]?.id == target else { return nil }
            return (row.id, entity)
        }
        guard targets.count == 1, let (targetID, owner) = targets.first,
            sceneModel?.subtreeEntityIDs(rootedAt: group.editorID).contains(targetID) == false,
            owner.components[MeshTerrain3DEdit.self] == nil, let original = owner.components[Terrain3DSource.self],
            let asset = owner.components[MeshTerrain3DSourceSurface.self]?.asset, let terrainMatrix = EditorPicking.worldMatrix(for: owner) else {
            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
        }
        let ownership = try MeshTerrain3DOwnership.capture(of: owner, in: world)
        var document = asset.document
        let updates = try bound.map { entity, binding in
            guard entity.components[MeshTerrain3DBindingStatus.self]?.phase == .applied,
                let identity = entity.components[MeshTerrain3DIdentity.self],
                let index = document.modifiers.firstIndex(where: { $0.id == binding.modifier }),
                let sourceMatrix = EditorPicking.worldMatrix(for: entity, overriding: [groupEntity.id: pose]) else {
                throw EditorTerrainSourceAuthoring.Failure.sourceChanged
            }
            document.modifiers[index].transform = terrainMatrix.inverse * sourceMatrix
            let sourceOwnership = try MeshTerrain3DOwnership.capture(of: owner, for: entity, in: world)
            return MeshTerrainBindingUpdate(entity: entity.id, modifier: binding.modifier, identity: identity, binding: binding,
                draws: Set(sourceOwnership.draws.map(\.entity)), collisions: Set(sourceOwnership.collisions))
        }
        let candidate = MeshTerrainDocumentAsset(document: document, populationRules: asset.populationRules,
            manualPlacements: asset.manualPlacements, populationOverrides: asset.populationOverrides)
        return (.init(owner: owner, original: original, previous: asset, candidate: candidate, previousOwnership: ownership,
            draws: ownership.draws, collisions: ownership.collisions, bindings: updates, previousBindings: updates,
            sourceTransforms: [.init(entity: groupEntity.id, pose: pose)], rollbackTransforms: [.init(entity: groupEntity.id, pose: group.initialPose)]), targetID)
    }

    private func commitMeshTerrainGroupFile(_ file: URL, targetID: String, assetsRoot: URL, expected: EditorSceneModel) throws {
        guard matchesMeshDragModel(expected), var model = sceneModel, let index = model.entities.firstIndex(where: { $0.id == targetID }) else {
            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
        }
        let root = assetsRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
        model.entities[index].components[EditorBuiltInComponentType.terrain3DSource]?["source"] = .string("@res://" + path.dropFirst(root.count + 1))
        sceneModel = model
        publishTerrainDocument()
        refreshTerrainSourceControls()
    }
}
