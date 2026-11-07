import AdaEngine
import Foundation

extension EditorAnimationAuthoringService {
    func openModifiers(_ path: String) throws -> EditorAnimationModifierDocument {
        let url = try resolve(path, extensions: ["animmod"])
        if let document = modifierDocuments[url.path], !document.isDiscarded { return document }
        let data = try readModifierBytes(url)
        let document = try EditorAnimationModifierDocument(url: url, relativePath: path, stack: AnimationModifierStack.decode(data),
                                                          savedBytes: data, resourceRoot: assetsURL)
        modifierDocuments[url.path] = document
        onModifierDocumentOpened?(document)
        return document
    }

    func createModifiers(_ path: String, binding: AnimationRigBinding) throws -> EditorAnimationModifierDocument {
        let url = try resolve(path, extensions: ["animmod"])
        guard modifierDocuments[url.path] == nil, !FileManager.default.fileExists(atPath: url.path) else { throw modifierFailure("IK resource already exists; inspect it before editing.") }
        let document = try EditorAnimationModifierDocument(url: url, relativePath: path, stack: .init(binding: binding), savedBytes: nil, resourceRoot: assetsURL)
        modifierDocuments[url.path] = document
        onModifierDocumentOpened?(document)
        return document
    }

    func closeModifiers(_ path: String, discardChanges: Bool = false) throws {
        let url = try resolve(path, extensions: ["animmod"])
        guard let document = modifierDocuments[url.path] else { return }
        guard !document.isDirty || discardChanges else { throw modifierFailure("Save or explicitly discard the IK draft before closing it.") }
        document.discard()
        modifierDocuments[url.path] = nil
        onModifierDocumentDiscarded?(document)
    }

    /// Every adapter calls this dispatcher; previews use the same production player as scene playback.
    func executeModifiers(_ request: AnimationAuthoringRequest, workbench: EditorWorkbenchViewModel) async throws -> [String: Any] {
        let generation = requestGeneration()
        if request.action == .modifierCreate {
            guard let modelPath = request.modelPath else { throw modifierFailure("modelPath is required to create IK resources.") }
            let rig = try await rigForModel(modelPath)
            try Task.checkCancellation()
            try checkGeneration(generation)
            return modifierAcknowledgement(try createModifiers(request.path, binding: .init(rig: rig, sourceAsset: modelPath)))
        }
        let document = try openModifiers(request.path)
        if let expected = request.expectedRevision { try document.checkRevision(expected) }
        if !request.action.isReadOnly { try document.checkRevision(request.expectedRevision ?? "") }
        switch request.action {
        case .modifierApply:
            guard let operations = request.modifierOperations else { throw modifierFailure("modifierOperations are required.") }
            var candidate = document.stack
            try candidate.apply(operations)
            try document.commit(candidate, expectedRevision: request.expectedRevision ?? "")
        case .modifierSave: try document.save(expectedRevision: request.expectedRevision ?? "")
        case .modifierUndo: try document.undo(expectedRevision: request.expectedRevision ?? "")
        case .modifierRedo: try document.redo(expectedRevision: request.expectedRevision ?? "")
        case .modifierReload:
            try document.reload(readModifierBytes(document.url), expectedRevision: request.expectedRevision ?? "", discardChanges: request.discardChanges == true)
        case .modifierDiscard:
            guard request.discardChanges == true else { throw modifierFailure("Discard requires discardChanges: true.") }
            try closeModifiers(request.path, discardChanges: true)
            onDocumentDiscarded?(request.path)
            return ["path": request.path, "discarded": true]
        case .modifierSample:
            let revision = document.revision
            var player: SkeletalAnimationPlayer
            if let clip = request.sourceClip {
                let imported = try await animationsForModel(document.stack.binding.sourceAsset)
                try checkGeneration(generation)
                try document.checkRevision(revision)
                guard document.stack.binding.isCompatible(with: imported.rig) else { throw AnimationPoseModifierError.incompatibleRig }
                player = try SkeletalAnimationPlayer(rig: imported.rig, clips: imported.clips)
                try player.play(clip, transitionDuration: 0)
            } else { player = try SkeletalAnimationPlayer(rig: document.stack.binding.makeRig(), clips: []) }
            guard (request.time ?? 0).isFinite else { throw modifierFailure("Sample time must be finite.") }
            try player.setPoseModifiers(document.stack.modifiers, binding: document.stack.binding)
            player.seek(to: request.time ?? 0)
            let offset = request.offset ?? 0, limit = request.limit ?? 128
            let poses = player.poses.enumerated().dropFirst(offset).prefix(limit).map { index, pose -> [String: Any] in
                let global = player.globalTransforms[index]
                return ["nodeID": document.stack.binding.nodes[index].id,
                        "translation": [pose.translation.x, pose.translation.y, pose.translation.z],
                        "rotation": [pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w],
                        "scale": [pose.scale.x, pose.scale.y, pose.scale.z],
                        "globalMatrixColumnMajor": (0..<4).flatMap { column in (0..<4).map { global[column, $0] } }]
            }
            var result = modifierAcknowledgement(document)
            result["poses"] = poses; result["offset"] = offset; result["total"] = player.poses.count
            result["diagnostics"] = modifierDiagnostics(player)
            result["rendered"] = false
            return result
        case .modifierPreview:
            guard let workspace = workbench.animationWorkspaces.values.first(where: { $0.modifiers === document }) else {
                throw modifierFailure("Open the IK resource or attach it in the Model panel before previewing.")
            }
            try workspace.requireNoUnkeyedPose()
            guard (request.time ?? 0).isFinite else { throw modifierFailure("Preview time must be finite.") }
            workspace.preview.playsAnimation = false
            workspace.timeline.inspectorMode = "modifiers"
            try workspace.preview.installPoseModifiers(document.stack)
            workspace.preview.seekGraph(to: request.time ?? 0)
            workbench.selectDocument(id: workspace.document.id)
            var result = modifierAcknowledgement(document)
            result["previewRequested"] = true; result["renderVerified"] = false
            return result
        case .modifierBind: try await bindModifiers(document, request: request, workbench: workbench)
        case .modifierInspect: break
        default: throw modifierFailure("Expected a modifier action.")
        }
        var result = modifierAcknowledgement(document)
        if request.action == .modifierInspect {
            result["binding"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.stack.binding))
            result["modifiers"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(document.stack.modifiers.dropFirst(request.offset ?? 0).prefix(request.limit ?? 128))))
            result["total"] = document.stack.modifiers.count
        }
        if request.action == .modifierBind { result["bound"] = true }
        return result
    }

    func modifierDiagnostics(_ player: SkeletalAnimationPlayer) -> [[String: Any]] {
        player.modifierDiagnostics.map { diagnostic in
            var value: [String: Any] = ["id": diagnostic.id, "status": diagnostic.status.rawValue, "iterations": diagnostic.iterations,
                                       "converged": diagnostic.status == .solved]
            if let error = diagnostic.solverError, error.isFinite { value["solverError"] = error }
            if let error = diagnostic.reachError, error.isFinite { value["reachError"] = error }
            return value
        }
    }

    private func bindModifiers(_ document: EditorAnimationModifierDocument, request: AnimationAuthoringRequest, workbench: EditorWorkbenchViewModel) async throws {
        let generation = requestGeneration()
        try document.requireSavedSnapshot()
        guard let scenePath = request.scenePath, let entityID = request.entityID,
              let scene = workbench.openDocuments.compactMap({ value -> EditorSceneDocument? in
                  if case let .scene(scene) = value, scene.relativePath == scenePath { return scene }; return nil
              }).first,
              !scene.isReadOnly, EditorAgentSceneToolService.revision(for: scene.content) == request.sceneRevision,
              let payload = scene.sceneModel?.entities.first(where: { $0.id == entityID })?.components[EditorBuiltInComponentType.model3DSource],
              var source = try EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.model3DSource, payload: payload) as? Model3DSource else {
            throw modifierFailure("Current scenePath, entityID and sceneRevision for an editable Model3DSource are required.")
        }
        let sceneURL = scene.absolutePath.map { URL(fileURLWithPath: $0) }
        let modelURL = try EditorModelResource.resolve(source.source, sourceURL: sceneURL, resourceRootURL: assetsURL)
        let imported = try await animationsForModel(String(modelURL.path.dropFirst(projectURL.path.count + 1)))
        try Task.checkCancellation()
        try checkGeneration(generation)
        try document.checkRevision(request.expectedRevision ?? "")
        try document.requireSavedSnapshot()
        guard workbench.animationService === self, modifierDocuments[document.url.path] === document,
              let current = workbench.sceneDocument(id: scene.id), !current.isReadOnly,
              EditorAgentSceneToolService.revision(for: current.content) == request.sceneRevision else { throw modifierFailure("Scene or IK resource changed during binding.") }
        let bindings = request.modifierBindings ?? source.modifierBindings
        for binding in bindings.values {
            for target in [binding.target, binding.pole].compactMap({ $0 }) {
                if let id = target.entity, current.sceneModel?.entities.contains(where: { $0.id == id }) != true {
                    throw modifierFailure("Scene target does not exist: \(id)")
                }
            }
        }
        source.animationModifiers = "@res://" + String(document.url.path.dropFirst(assetsURL.path.count + 1))
        source.modifierBindings = bindings
        try source.validateModifiers(document.stack, rig: imported.rig)
        var candidate = payload
        candidate["animationModifiers"] = .string(source.animationModifiers ?? "")
        candidate["modifierBindings"] = try JSONDecoder().decode(EditorSceneValue.self, from: JSONEncoder().encode(bindings))
        workbench.updateSceneModelDocument(id: current.id, status: "Animation modifiers bound") { model in
            if let index = model.entities.firstIndex(where: { $0.id == entityID }) {
                model.entities[index].components[EditorBuiltInComponentType.model3DSource] = candidate
            }
        }
    }

    private func readModifierBytes(_ url: URL) throws -> Data {
        guard try resolve(String(url.path.dropFirst(projectURL.path.count + 1)), extensions: ["animmod"]) == url,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= AnimationModifierStack.maximumEncodedBytes else {
            throw AnimationPoseModifierError.limitExceeded
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AnimationModifierStack.maximumEncodedBytes + 1) ?? Data()
        guard data.count <= AnimationModifierStack.maximumEncodedBytes else { throw AnimationPoseModifierError.limitExceeded }
        return data
    }

    private func modifierAcknowledgement(_ document: EditorAnimationModifierDocument) -> [String: Any] {
        ["path": document.relativePath, "revision": document.revision, "dirty": document.isDirty,
         "canUndo": document.canUndo, "canRedo": document.canRedo, "saved": !document.isDirty]
    }

    private func modifierFailure(_ message: String) -> AnimationAuthoringError { .init(.conflict, itemID: "modifiers", message: message) }
}
