@_spi(AdaEngine) import AdaEngine
import Foundation

/// Prepares immutable resources off the UI actor; publication and scene history share a safe point.
@MainActor
enum EditorMeshTerrainTransaction {
    struct Input {
        let owner: Entity
        let original: Terrain3DSource
        let previous: MeshTerrainDocumentAsset
        let candidate: MeshTerrainDocumentAsset
        let previousOwnership: MeshTerrain3DOwnership
        let draws: [MeshTerrainDrawReplacement]
        let collisions: [Entity.ID]
        let bindings: [MeshTerrainBindingUpdate]
        let previousBindings: [MeshTerrainBindingUpdate]
        var sourceTransforms: [MeshTerrainSourceTransform] = []
        var rollbackAsset: MeshTerrainDocumentAsset?
        var rollbackTransforms: [MeshTerrainSourceTransform] = []
        var resourceCommand: EditorTerrainStrokeCommand?
    }

    static func run(_ input: Input, application: AppWorlds, isCurrent: () -> Bool,
                    onProgress: (String) -> Void, commit: (URL) throws -> Void) async throws {
        onProgress("Preparing mesh terrain…")
        let compiled = (try? input.candidate.acceptedCompiledProduct()) != nil ? input.candidate : try await input.candidate.compiling()
        try Task.checkCancellation()
        guard isCurrent() else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
        onProgress("Saving mesh terrain…")
        let original = URL(fileURLWithPath: input.original.source)
        let (file, receipt): (URL, EditorMeshTerrainCreation.Receipt)
        if let command = input.resourceCommand {
            (file, receipt) = try await EditorMeshTerrainCreation.forkResources(command, from: original)
        } else {
            (file, receipt) = try await EditorMeshTerrainCreation.fork(compiled, from: original)
        }
        var request: MeshTerrain3DEdit?
        do {
            try await application.withWorldAccess {
                guard isCurrent(), application.main.getEntityByID(input.owner.id) === input.owner,
                    input.owner.components[Terrain3DSource.self] == input.original,
                    input.owner.components[MeshTerrain3DEdit.self] == nil else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                let value = MeshTerrain3DEdit(expectedInputKey: try input.previous.authoringKey(), candidate: compiled,
                    sourceTransforms: input.sourceTransforms,
                    drawReplacements: input.draws, collisionReplacements: input.collisions, adoptionManifest: file.path,
                    bindingUpdates: input.bindings)
                request = value
                input.owner.components[MeshTerrain3DEdit.self] = value
            }
            onProgress("Updating mesh terrain…")
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while true {
                let committed = try await application.withWorldAccess {
                    guard isCurrent(), application.main.getEntityByID(input.owner.id) === input.owner else {
                        throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                    }
                    guard let status = input.owner.components[MeshTerrain3DEditStatus.self], status.id == request?.id else { return false }
                    switch status.phase {
                    case .pending: return false
                    case .failed: throw EditorTerrainSourceAuthoring.Failure.failed(status.error ?? "Mesh Terrain could not be updated.")
                    case .cancelled: throw CancellationError()
                    case .applied:
                        guard input.owner.components[Terrain3DSource.self]?.source == file.path else {
                            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                        }
                        try commit(file)
                        return true
                    }
                }
                if committed { return }
                guard ContinuousClock.now < deadline else { throw EditorTerrainSourceAuthoring.Failure.timedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            // A cancellation must still reach a world safe point and undo a generation that
            // completed just before Escape. Never remove a resource still referenced by a live owner.
            let removable = await Task { @MainActor in
                do {
                    let rollback = try await application.withWorldAccess { () throws -> MeshTerrain3DEdit? in
                        guard application.main.getEntityByID(input.owner.id) === input.owner else { return nil }
                        if input.owner.components[MeshTerrain3DEdit.self]?.id == request?.id { input.owner.components.remove(MeshTerrain3DEdit.self) }
                        let currentPath = input.owner.components[Terrain3DSource.self]?.source
                        guard currentPath == file.path || (input.rollbackAsset != nil && currentPath == input.original.source) else { return nil }
                        guard try input.owner.components[MeshTerrain3DSourceSurface.self]?.asset.authoringKey() == compiled.authoringKey(),
                            input.owner.components[MeshTerrain3DEdit.self] == nil else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                        let rollback = MeshTerrain3DEdit(expectedInputKey: try compiled.authoringKey(), candidate: input.rollbackAsset ?? input.previous,
                            sourceTransforms: input.rollbackTransforms,
                            drawReplacements: input.previousOwnership.draws, collisionReplacements: input.previousOwnership.collisions,
                            adoptionManifest: input.original.source, bindingUpdates: input.previousBindings)
                        input.owner.components[MeshTerrain3DEdit.self] = rollback
                        return rollback
                    }
                    if let rollback {
                        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                        while ContinuousClock.now < deadline {
                            let done = try await application.withWorldAccess {
                                guard application.main.getEntityByID(input.owner.id) === input.owner else { return true }
                                guard let status = input.owner.components[MeshTerrain3DEditStatus.self], status.id == rollback.id else { return false }
                                return status.phase != .pending
                            }
                            if done { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                    return try await application.withWorldAccess {
                        application.main.getEntityByID(input.owner.id) !== input.owner || input.owner.components[Terrain3DSource.self]?.source != file.path
                    }
                } catch { return false }
            }.value
            if removable { await EditorMeshTerrainCreation.discard(receipt) }
            throw error
        }
    }
}
