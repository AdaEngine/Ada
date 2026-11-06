@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorAnimationAuthoringService {
    /// Canvas, agent and Tool clients share this workspace graph and its semantic Undo history.
    func executeGraph(_ request: AnimationAuthoringRequest, workbench: EditorWorkbenchViewModel) async throws -> [String: Any] {
        let url = try resolve(request.path, extensions: ["glb", "gltf", "animlib"])
        guard let document = workbench.openDocuments.compactMap({ value -> EditorAssetDocument? in
            if case let .asset(asset) = value, asset.relativePath == request.path { return asset }
            return nil
        }).first, document.absolutePath.map({ Self.canonicalDestination(URL(fileURLWithPath: $0)) }) == url else {
            throw graphFailure("Open the model or animation library asset before inspecting its graph.")
        }
        let workspace = workbench.animationWorkspace(for: document)
        let model = workspace.graph
        if let expected = request.expectedRevision { try model.checkRevision(expected) }
        if request.action != .graphInspect {
            try workspace.requireNoUnkeyedPose()
            try model.checkRevision(request.expectedRevision ?? "")
            guard model.rig != nil else { throw graphFailure("Wait for the model viewport to load its animation rig.") }
        }
        switch request.action {
        case .graphApply:
            guard let graph = request.graph else { throw graphFailure("graph is required.") }
            try model.applyGraph(graph, expectedRevision: request.expectedRevision ?? "")
        case .graphUndo: model.undoCanvas()
        case .graphRedo: model.redoCanvas()
        case .graphPreview:
            guard model.validGraph != nil, (request.time ?? 0).isFinite else { throw graphFailure("A valid graph and finite time are required.") }
            workspace.mode = .graph
            workspace.timeline.inspectorMode = "graph"
            workspace.preview.playsAnimation = false
            workspace.applyModePreview()
            workspace.preview.seekGraph(to: request.time ?? 0)
            workbench.selectDocument(id: document.id)
        case .graphBind:
            try await bindWorkspaceGraph(workspace, request: request, workbench: workbench)
        case .graphInspect: break
        default: throw graphFailure("Expected a graph action.")
        }
        var result: [String: Any] = ["path": request.path, "revision": model.revision, "ready": model.rig != nil,
            "valid": model.validGraph != nil, "root": model.graph.root, "total": model.graph.nodes.count,
            "canUndo": !model.undoStack.isEmpty, "canRedo": !model.redoStack.isEmpty, "renderVerified": false]
        if let error = model.validationMessage { result["diagnostic"] = error }
        if let library = workspace.library { result["resourceRevision"] = library.revision }
        if request.action == .graphInspect {
            let offset = request.offset ?? 0, limit = request.limit ?? 128
            let nodes = Array(model.graph.nodes.dropFirst(offset).prefix(limit))
            result["offset"] = offset
            result["nodes"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nodes))
        }
        if request.action == .graphPreview { result["previewRequested"] = true }
        if request.action == .graphBind { result["bound"] = true }
        return result
    }

    private func bindWorkspaceGraph(_ workspace: EditorAnimationAssetWorkspace, request: AnimationAuthoringRequest,
                                    workbench: EditorWorkbenchViewModel) async throws {
        let generation = requestGeneration()
        guard let graph = workspace.graph.validGraph, let path = request.scenePath, let entityID = request.entityID,
              let scene = workbench.openDocuments.compactMap({ value -> EditorSceneDocument? in
                  if case let .scene(scene) = value, scene.relativePath == path { return scene }
                  return nil
              }).first, !scene.isReadOnly,
              EditorAgentSceneToolService.revision(for: scene.content) == request.sceneRevision,
              let payload = scene.sceneModel?.entities.first(where: { $0.id == entityID })?.components[EditorBuiltInComponentType.model3DSource],
              var candidate = try EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.model3DSource, payload: payload) as? Model3DSource else {
            throw graphFailure("Current scenePath, entityID and sceneRevision for a Model3DSource are required.")
        }
        let source = candidate
        let sceneURL = scene.absolutePath.map { URL(fileURLWithPath: $0) }
        let modelURL = try EditorModelResource.resolve(candidate.source, sourceURL: sceneURL, resourceRootURL: assetsURL)
        let documents = try savedDocuments(references: candidate.animationLibraries, sceneURL: sceneURL)
        let revisions = documents.map(\.revision)
        let imported = try await animationsForModel(String(modelURL.path.dropFirst(projectURL.path.count + 1)))
        try Task.checkCancellation()
        try checkGeneration(generation)
        try workspace.requireNoUnkeyedPose()
        try workspace.graph.checkRevision(request.expectedRevision ?? "")
        guard let authoredRig = workspace.graph.rig,
              AnimationRigBinding(rig: authoredRig, sourceAsset: "").nodes == AnimationRigBinding(rig: imported.rig, sourceAsset: "").nodes else {
            throw AnimationAuthoringError(.incompatibleRig, itemID: entityID, message: "Destination rig differs from the graph workspace; remap masks explicitly.")
        }
        guard workbench.animationService === self, workbench.animationWorkspaces[workspace.document.id] === workspace,
              workbench.openDocuments.contains(where: { $0.id == workspace.document.id }),
              let current = workbench.sceneDocument(id: scene.id), !current.isReadOnly,
              EditorAgentSceneToolService.revision(for: current.content) == request.sceneRevision else {
            throw graphFailure("Scene or workspace changed during binding; inspect and retry.")
        }
        for (document, revision) in zip(documents, revisions) {
            try document.checkRevision(revision)
            try document.requireSavedSnapshot()
        }
        candidate.animationGraph = graph
        _ = try candidate.resolvedAnimationClips(importedClips: imported.clips, rig: imported.rig, libraries: documents.map(\.library))
        guard try workbench.setAnimationGraph(graph, target: .init(documentID: scene.id, entityID: entityID, source: source, sceneURL: sceneURL)) else {
            throw graphFailure("Scene target is unavailable.")
        }
    }

    private func graphFailure(_ message: String) -> AnimationAuthoringError { .init(.conflict, itemID: "graph", message: message) }
}
