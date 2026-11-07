@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorSceneViewportModel {
    /// A narrow scene-history delta retains mesh, queries and source draws until
    /// their saved generation is ready. Other scene changes use normal loading.
    func restoreMeshTerrainHistory(previous: EditorSceneModel, next: EditorSceneModel, sourceURL: URL?) -> Bool {
        guard !terrainEditing.isSourceBusy || terrainEditing.meshHistoryQueue.isRunning, let context = terrainSourceContext,
            let plan = try? EditorMeshTerrainHistory.Plan.make(previous: previous, next: next),
            let owner = runtimeEntity(for: plan.ownerEditorID), owner.components[MeshTerrain3DSourceSurface.self] != nil else { return false }
        var roots: [String: Entity] = [:]
        for source in plan.sources {
            guard let root = runtimeEntity(for: source.editorID) else { return false }
            roots[source.editorID] = root
        }
        let generation = UUID()
        terrainEditing.sourceGeneration = generation
        terrainEditing.isSourceBusy = true
        terrainEditing.sourceFailure = nil
        terrainEditing.sourceStatus = "Restoring Mesh Terrain…"
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            var current = self.sceneModel, expected = next
            current?.editor = nil; expected.editor = nil
            return self.terrainEditing.sourceGeneration == generation && current == expected
        }
        terrainEditing.sourceTask = terrainEditing.meshHistoryQueue.submit(.init(
            apply: { [weak self] in
                try Task.checkCancellation()
                let file = try EditorTerrainResource.resolve(plan.uri, sourceURL: sourceURL, resourceRootURL: context.assetsRoot)
                let asset = try await EditorMeshTerrainHistory.prepare(file)
                try Task.checkCancellation()
                try await EditorMeshTerrainHistory.apply(plan, candidate: asset, file: file, owner: owner, roots: roots,
                    application: context.application, isCurrent: isCurrent)
                if let self, isCurrent() {
                    self.refreshTerrainSourceControls()
                    if let model = self.sceneModel { self.onSelectionChanged?(self.selectedEntityViewModel(editorID: self.selectedEditorID, model: model)) }
                }
            },
            failed: { [weak self] error in
                guard let self, isCurrent() else { return }
                self.terrainEditing.sourceStatus = "Mesh Terrain could not be updated."
                self.terrainEditing.sourceFailure = error
            },
            finished: { [weak self] in self?.finishSourceTerrainTask(generation: generation) }
        ))
        return true
    }
}
