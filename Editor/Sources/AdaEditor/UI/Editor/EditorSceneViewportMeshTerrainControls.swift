@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorSceneViewportModel {
    /// Refresh only on selection/installation, with bounded retries while immutable resources load.
    func refreshMeshTerrainControls() {
        terrainEditing.meshControlsTask?.cancel()
        terrainEditing.meshControlsGeneration = UUID()
        let generation = terrainEditing.meshControlsGeneration
        let selectedID = selectedEditorID
        terrainEditing.meshHasBinding = sceneModel?.entities.first(where: { $0.id == selectedID })?
            .components[String(reflecting: MeshTerrain3DBinding.self)] != nil
        guard terrainEditing.isEnabled, let context = terrainSourceContext else {
            terrainEditing.meshTargets = []; terrainEditing.meshSourceName = nil
            return
        }
        let changedSelection = terrainEditing.meshSourceEditorID != selectedID
        terrainEditing.meshSourceEditorID = selectedID
        if changedSelection { terrainEditing.meshSelectedParts = []; terrainEditing.meshControlsBinding = nil }
        terrainEditing.meshControlsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.terrainEditing.meshControlsGeneration == generation { self.terrainEditing.meshControlsTask = nil } }
            for _ in 0..<200 {
                do {
                    let snapshot = try await context.application.withWorldAccess { self.meshTerrainControlsSnapshot(selectedID: selectedID) }
                    guard !Task.isCancelled, self.terrainEditing.meshControlsGeneration == generation else { return }
                    self.terrainEditing.meshTargets = snapshot.targets
                    self.terrainEditing.meshSourceName = snapshot.sourceName
                    if let bound = snapshot.boundTarget { self.terrainEditing.meshTargetEditorID = bound }
                    else if !snapshot.targets.contains(where: { $0.id == self.terrainEditing.meshTargetEditorID }) {
                        self.terrainEditing.meshTargetEditorID = snapshot.targets.first?.id
                    }
                    if snapshot.binding != self.terrainEditing.meshControlsBinding {
                        self.terrainEditing.meshControlsBinding = snapshot.binding
                        if let binding = snapshot.binding { self.restoreMeshTerrainControlValues(binding) }
                    }
                    if !snapshot.pending { return }
                    try await Task.sleep(for: .milliseconds(50))
                } catch { return }
            }
        }
    }

    private func restoreMeshTerrainControlValues(_ binding: MeshTerrain3DBinding) {
        terrainEditing.meshSelectedParts = binding.parts
        terrainEditing.meshContactWidth = binding.contactWidth
        switch binding.operation {
        case .subtract: terrainEditing.meshOperation = "Subtract"
        case let .conform(_, distance, strength):
            terrainEditing.meshOperation = "Conform"
            terrainEditing.meshConformDistance = distance
            terrainEditing.meshConformStrength = strength
        default: terrainEditing.meshOperation = "Join"
        }
    }

    private struct MeshTerrainControlsSnapshot {
        let targets: [EditorMeshTerrainTarget]
        let sourceName: String?
        let boundTarget: String?
        let binding: MeshTerrain3DBinding?
        let pending: Bool
    }

    private func meshTerrainControlsSnapshot(selectedID: String?) -> MeshTerrainControlsSnapshot {
        var targets: [EditorMeshTerrainTarget] = [], identities: [UUID: String] = [:], pending = false
        for entity in sceneModel?.entities ?? [] where entity.components[EditorBuiltInComponentType.terrain3DSource] != nil {
            guard let owner = runtimeEntity(for: entity.id), let identity = owner.components[MeshTerrain3DIdentity.self] else { continue }
            if owner.components[MeshTerrain3DSourceSurface.self] != nil {
                targets.append(.init(id: entity.id, name: entity.name)); identities[identity.id] = entity.id
            } else if owner.components[Terrain3DSourceStatus.self]?.error == nil { pending = true }
        }
        var sourceName: String?, binding: MeshTerrain3DBinding?
        if let selectedID, let source = runtimeEntity(for: selectedID), source.components[Terrain3DSource.self] == nil {
            binding = source.components[MeshTerrain3DBinding.self]
            if (try? MeshTerrainSourceCapture.capture(source, parts: binding?.parts ?? terrainEditing.meshSelectedParts)) != nil {
                sourceName = sceneModel?.entities.first { $0.id == selectedID }?.name
            } else if source.components[Model3DSource.self] != nil { pending = true }
        }
        return .init(targets: targets, sourceName: sourceName, boundTarget: binding.flatMap { identities[$0.target] }, binding: binding, pending: pending)
    }
}
