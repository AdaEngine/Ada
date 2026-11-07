@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorSceneViewportModel {
    func beginMeshTerrainDrag(editorID: String, payload: EditorComponentPayload, pose: Transform) -> Bool {
        let descendants = meshTerrainBoundDescendants(of: editorID)
        if !descendants.isEmpty { return beginMeshTerrainGroupDrag(editorID: editorID, descendants: descendants, payload: payload, pose: pose) }
        guard let source = runtimeEntity(for: editorID), let binding = source.components[MeshTerrain3DBinding.self], binding.enabled else { return true }
        guard !terrainEditing.isSourceBusy, TriangleMeshBoolean.isAvailable, let context = terrainSourceContext else { return false }
        let targets = (sceneModel?.entities ?? []).compactMap { entity -> (String, Entity)? in
            guard let owner = runtimeEntity(for: entity.id), owner.components[MeshTerrain3DSourceSurface.self] != nil,
                owner.components[MeshTerrain3DIdentity.self]?.id == binding.target else { return nil }
            return (entity.id, owner)
        }
        guard targets.count == 1, let target = targets.first else { return false }
        let generation = UUID()
        terrainEditing.sourceGeneration = generation
        terrainEditing.isSourceBusy = true
        terrainEditing.sourceFailure = nil
        terrainEditing.sourceStatus = "Moving joined mesh…"
        terrainEditing.meshDragSession = .init(sourceEditorID: editorID, targetEditorID: target.0, source: source, owner: target.1,
            initialPose: pose, initialPayload: payload, initialContent: sceneContent, generation: generation, application: context.application)
        return true
    }

    func finishMeshTerrainDrag(_ session: EditorMeshTerrainDragSession, cancelled: Bool) {
        guard let context = terrainSourceContext else { return }
        let expectedModel = sceneModel
        let payload = sceneModel?.entities.first { $0.id == session.sourceEditorID }?.components[EditorBuiltInComponentType.transform]
        let finalPose = try? payload.flatMap { try EditorComponentPayloadDecoder.decode(Transform.self, payload: $0) as? Transform }
        if cancelled { terrainEditing.meshPoseQueue.discard(session.source.id) }
        terrainEditing.sourceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var captured: EditorMeshTerrainDragSession.Snapshot?
            do {
                let snapshot = try await session.captured.value
                captured = snapshot
                if cancelled { throw CancellationError() }
                guard let finalPose, let expectedModel else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                let asset = try await self.awaitMeshTerrainPose(session, pose: finalPose, application: context.application)
                let ownership = try await context.application.withWorldAccess { try MeshTerrain3DOwnership.capture(of: session.owner, in: context.application.main) }
                let input = EditorMeshTerrainTransaction.Input(owner: session.owner, original: snapshot.source, previous: asset, candidate: asset,
                    previousOwnership: snapshot.ownership, draws: ownership.draws, collisions: ownership.collisions,
                    bindings: [session.bindingUpdate(snapshot)], previousBindings: [session.bindingUpdate(snapshot)],
                    sourceTransforms: [.init(entity: session.source.id, pose: finalPose)], rollbackAsset: snapshot.asset,
                    rollbackTransforms: [.init(entity: session.source.id, pose: session.initialPose)])
                try await EditorMeshTerrainTransaction.run(input, application: context.application,
                    isCurrent: { self.terrainEditing.sourceGeneration == session.generation && self.matchesMeshDragModel(expectedModel) },
                    onProgress: { self.terrainEditing.sourceStatus = $0 },
                    commit: { file in
                        guard self.matchesMeshDragModel(expectedModel), var model = self.sceneModel,
                            let index = model.entities.firstIndex(where: { $0.id == session.targetEditorID }) else {
                            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                        }
                        let root = context.assetsRoot.resolvingSymlinksInPath().standardizedFileURL
                        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
                        guard path.hasPrefix(root.path + "/") else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                        model.entities[index].components[EditorBuiltInComponentType.terrain3DSource]?["source"] = .string("@res://" + path.dropFirst(root.path.count + 1))
                        self.sceneModel = model
                        self.publishTerrainDocument()
                        self.refreshTerrainSourceControls()
                    })
            } catch {
                let failed = !(error is CancellationError)
                // Always reach a world safe point after cancellation. Incoming document
                // replacement owns its own runtime; never restore over that scene.
                if self.sceneContent == session.initialContent {
                    self.terrainEditing.meshPoseQueue.discard(session.source.id)
                    let restoreFailure = await Task { @MainActor () -> String? in
                        do {
                            if let captured { try await self.restoreMeshTerrainDrag(session, snapshot: captured, application: context.application) }
                            try await self.synchronizeMeshDragInspector(session, application: context.application)
                            return nil
                        } catch {
                            try? await self.synchronizeMeshDragInspector(session, application: context.application)
                            return error.localizedDescription
                        }
                    }.value
                    if let restoreFailure, self.terrainEditing.sourceGeneration == session.generation {
                        self.terrainEditing.sourceStatus = "Mesh Terrain could not be restored. The last valid surface is still visible."
                        self.terrainEditing.sourceFailure = restoreFailure
                    }
                }
                if failed, self.terrainEditing.sourceFailure == nil, self.terrainEditing.sourceGeneration == session.generation {
                    self.terrainEditing.sourceStatus = "Mesh Terrain could not be updated."
                    self.terrainEditing.sourceFailure = error.localizedDescription
                }
            }
            if self.terrainEditing.meshDragSession === session { self.terrainEditing.meshDragSession = nil }
            self.finishSourceTerrainTask(generation: session.generation)
            if let model = self.sceneModel { self.onSelectionChanged?(self.selectedEntityViewModel(editorID: self.selectedEditorID, model: model)) }
        }
    }

    func matchesMeshDragModel(_ expected: EditorSceneModel) -> Bool {
        var current = sceneModel, expected = expected
        current?.editor = nil; expected.editor = nil
        return current == expected
    }

    private func awaitMeshTerrainPose(_ session: EditorMeshTerrainDragSession, pose: Transform, application: AppWorlds) async throws -> MeshTerrainDocumentAsset {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let asset = try await application.withWorldAccess({ () throws -> MeshTerrainDocumentAsset? in
                guard self.terrainEditing.sourceGeneration == session.generation,
                    application.main.getEntityByID(session.source.id) === session.source,
                    application.main.getEntityByID(session.owner.id) === session.owner else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                if let status = session.source.components[MeshTerrain3DBindingStatus.self], status.phase == .failed || status.phase == .orphaned {
                    throw EditorTerrainSourceAuthoring.Failure.failed(status.error ?? "Mesh Terrain could not be updated.")
                }
                guard session.source.components[Transform.self] == pose, session.source.components[MeshTerrain3DProposedPose.self] == nil,
                    session.source.components[MeshTerrain3DBindingStatus.self]?.phase == .applied else { return nil }
                return session.owner.components[MeshTerrain3DSourceSurface.self]?.asset
            }) { return asset }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EditorTerrainSourceAuthoring.Failure.timedOut
    }

    private func synchronizeMeshDragInspector(_ session: EditorMeshTerrainDragSession, application: AppWorlds) async throws {
        try await application.withWorldAccess {
            guard self.sceneContent == session.initialContent, application.main.getEntityByID(session.source.id) === session.source,
                var model = self.sceneModel, let index = model.entities.firstIndex(where: { $0.id == session.sourceEditorID }),
                let pose = session.source.components[Transform.self] else { return }
            let current = model.entities[index].components[EditorBuiltInComponentType.transform]
            let currentPose = try current.flatMap { try EditorComponentPayloadDecoder.decode(Transform.self, payload: $0) as? Transform }
            let payload: EditorComponentPayload
            if pose == session.initialPose { payload = session.initialPayload }
            else if pose == currentPose, let current { payload = current }
            else { payload = try JSONDecoder().decode(EditorComponentPayload.self, from: JSONEncoder().encode(pose)) }
            model.entities[index].components[EditorBuiltInComponentType.transform] = payload
            self.sceneModel = model
            self.onTransformChanged?(session.sourceEditorID, payload)
        }
    }

    private func restoreMeshTerrainDrag(_ session: EditorMeshTerrainDragSession, snapshot: EditorMeshTerrainDragSession.Snapshot, application: AppWorlds) async throws {
        let request = try await application.withWorldAccess { () throws -> MeshTerrain3DEdit? in
            guard application.main.getEntityByID(session.source.id) === session.source,
                application.main.getEntityByID(session.owner.id) === session.owner else { return nil }
            guard
                let source = session.owner.components[Terrain3DSource.self], source.source == snapshot.source.source,
                let asset = session.owner.components[MeshTerrain3DSourceSurface.self]?.asset,
                session.source.components[MeshTerrain3DBinding.self] == snapshot.binding else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
            // The mailbox may have been cancelled before the first scene update.
            // Its already validated generation needs no queued work to restore.
            if let initialKey = snapshot.asset.compiled?.inputKey, asset.compiled?.inputKey == initialKey,
                session.source.components[Transform.self] == session.initialPose,
                session.source.components[MeshTerrain3DProposedPose.self] == nil,
                session.owner.components[MeshTerrain3DEdit.self] == nil,
                session.source.components[MeshTerrain3DBindingStatus.self]?.phase == .applied { return nil }
            let request = MeshTerrain3DEdit(expectedInputKey: try asset.authoringKey(), candidate: snapshot.asset,
                sourceTransforms: [.init(entity: session.source.id, pose: session.initialPose)], drawReplacements: snapshot.ownership.draws,
                collisionReplacements: snapshot.ownership.collisions, bindingUpdates: [session.bindingUpdate(snapshot)])
            session.owner.components[MeshTerrain3DEdit.self] = request
            return request
        }
        guard let request else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            let done = try await application.withWorldAccess { () throws -> Bool in
                guard application.main.getEntityByID(session.owner.id) === session.owner else { return true }
                guard let status = session.owner.components[MeshTerrain3DEditStatus.self], status.id == request.id else { return false }
                switch status.phase {
                case .pending: return false
                case .failed: throw EditorTerrainSourceAuthoring.Failure.failed(status.error ?? "Mesh Terrain could not be updated.")
                case .cancelled: throw EditorTerrainSourceAuthoring.Failure.failed("Mesh Terrain restoration was cancelled.")
                case .applied:
                    guard session.owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == snapshot.asset.compiled?.inputKey,
                        session.source.components[Transform.self] == session.initialPose else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                    return true
                }
            }
            if done { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EditorTerrainSourceAuthoring.Failure.timedOut
    }
}
