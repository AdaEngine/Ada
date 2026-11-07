@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorSceneViewportModel {
    func performMeshTerrainResources(_ command: EditorTerrainStrokeCommand) {
        guard !terrainEditing.isSourceBusy, let context = terrainSourceContext, let editorID = selectedEditorID,
            let baseline = sceneModel else { return }
        let generation = UUID()
        terrainEditing.sourceGeneration = generation
        terrainEditing.isSourceBusy = true
        terrainEditing.sourceFailure = nil
        terrainEditing.sourceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishSourceTerrainTask(generation: generation) }
            let isCurrent = {
                var expected = baseline, current = self.sceneModel
                expected.editor = nil; current?.editor = nil
                return self.terrainEditing.sourceGeneration == generation && current == expected
                    && self.terrainSourceContext?.application === context.application && self.terrainSourceContext?.assetsRoot == context.assetsRoot
            }
            do {
                let input = try await context.application.withWorldAccess { () throws -> EditorMeshTerrainTransaction.Input? in
                    guard isCurrent(), let owner = self.runtimeEntity(for: editorID), let surface = owner.components[MeshTerrain3DSourceSurface.self],
                        let resources = owner.components[MeshTerrain3DSourceResources.self],
                        let source = owner.components[Terrain3DSource.self] else { throw EditorTerrainSourceAuthoring.Failure.unavailable }
                    if case let .materials(palette) = command, resources.manifest.materials == palette { return nil }
                    let ownership = try MeshTerrain3DOwnership.capture(of: owner, in: context.application.main)
                    return .init(owner: owner, original: source, previous: surface.asset, candidate: surface.asset, previousOwnership: ownership,
                        draws: ownership.draws, collisions: ownership.collisions, bindings: [], previousBindings: [], resourceCommand: command)
                }
                guard let input else { return }
                try await EditorMeshTerrainTransaction.run(input, application: context.application, isCurrent: isCurrent,
                    onProgress: { self.terrainEditing.sourceStatus = $0 }, commit: { file in
                        guard isCurrent(), let index = self.sceneModel?.entities.firstIndex(where: { $0.id == editorID }) else {
                            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                        }
                        let root = context.assetsRoot.resolvingSymlinksInPath().standardizedFileURL.path
                        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
                        guard path.hasPrefix(root + "/") else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                        self.sceneModel?.entities[index].components[EditorBuiltInComponentType.terrain3DSource]?["source"] = .string("@res://" + path.dropFirst(root.count + 1))
                        self.publishTerrainDocument()
                        self.refreshTerrainSourceControls()
                    })
            } catch is CancellationError {
            } catch {
                if self.terrainEditing.sourceGeneration == generation {
                    self.terrainEditing.sourceStatus = "Mesh Terrain could not be updated."
                    self.terrainEditing.sourceFailure = error.localizedDescription
                }
            }
        }
    }
}
