import AdaEngine
import Foundation

extension EditorWorkbenchViewModel {
    /// Asset Save and scene binding are separate transactions; scene changes use ordinary history.
    func bindAnimationLibrary(_ document: EditorAnimationLibraryDocument, sceneID: String, entityID: String,
                              expectedSceneRevision: String, expectedResourceRevision: String, clipID: String) async throws {
        guard let service = animationService, let scene = sceneDocument(id: sceneID), !scene.isReadOnly,
            let entity = scene.sceneModel?.entities.first(where: { $0.id == entityID }),
            let payload = entity.components[EditorBuiltInComponentType.model3DSource],
            let source = payload["source"]?.stringValue,
            EditorAgentSceneToolService.revision(for: scene.content) == expectedSceneRevision else {
            throw AnimationAuthoringError(.conflict, itemID: entityID, message: "Open editable scene and current scene revision are required for binding.")
        }
        try document.checkRevision(expectedResourceRevision)
        try document.requireSavedSnapshot()
        guard let clip = document.library.clips.first(where: { $0.id == clipID }) else {
            throw AnimationAuthoringError(.missingClip, itemID: clipID, message: "Clip does not exist.")
        }
        let reference = "@res://" + String(document.url.path.dropFirst(service.assetsURL.path.count + 1))
        var candidatePayload = payload
        var references: [String] = []
        if case let .array(values) = payload["animationLibraries"] {
            references = try values.map { value in
                guard case let .string(path) = value else {
                    throw AnimationAuthoringError(.missingTarget, itemID: entityID, message: "Animation library references must be strings.")
                }
                return path
            }
        }
        let previousDocuments = try service.savedDocuments(references: references, sceneURL: scene.absolutePath.map { URL(fileURLWithPath: $0) })
        if !previousDocuments.contains(where: { $0.url == document.url }) { references.append(reference) }
        candidatePayload["animationLibraries"] = .array(references.map(EditorSceneValue.string))
        if payload["animationGraph"] == nil || payload["animationGraph"] == .null {
            candidatePayload["animation"] = .string(document.library.runtimeName(for: clip.id))
            candidatePayload["repeats"] = .bool(clip.repeats)
        }
        guard let candidate = try EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.model3DSource, payload: candidatePayload) as? Model3DSource else {
            throw AnimationAuthoringError(.invalidTrack, itemID: entityID, message: "Invalid Model3DSource binding.")
        }
        let documents = try service.savedDocuments(references: references, sceneURL: scene.absolutePath.map { URL(fileURLWithPath: $0) })
        let revisions = documents.map(\.revision)
        let url = try EditorModelResource.resolve(source, sourceURL: scene.absolutePath.map { URL(fileURLWithPath: $0) }, resourceRootURL: service.assetsURL)
        let modelPath = String(url.path.dropFirst(service.projectURL.path.count + 1))
        let imported = try await service.animationsForModel(modelPath)
        try Task.checkCancellation()
        _ = try candidate.resolvedAnimationClips(importedClips: imported.clips, rig: imported.rig, libraries: documents.map(\.library))
        for (library, revision) in zip(documents, revisions) {
            try library.checkRevision(revision)
            try library.requireSavedSnapshot()
        }
        try document.checkRevision(expectedResourceRevision)
        try document.requireSavedSnapshot()
        guard let current = sceneDocument(id: sceneID), !current.isReadOnly,
            EditorAgentSceneToolService.revision(for: current.content) == expectedSceneRevision else {
            throw AnimationAuthoringError(.conflict, itemID: sceneID, message: "Scene or animation changed during binding; inspect and retry.")
        }
        updateSceneModelDocument(id: sceneID, status: "Animation library bound") { model in
            guard let index = model.entities.firstIndex(where: { $0.id == entityID }) else { return }
            model.entities[index].components[EditorBuiltInComponentType.model3DSource] = candidatePayload
        }
    }

    /// Placement validates saved resources and the current CPU import before a single scene-history edit.
    func addAnimatedModelAsset(_ asset: EditorAssetDocument, to sceneID: String, animation: String,
                               autoplay: Bool, repeats: Bool, graph: AnimationGraph?, library: EditorAnimationLibraryDocument?) async throws -> Bool {
        guard let service = animationService, let reference = asset.assetReference,
            let scene = sceneDocument(id: sceneID), !scene.isReadOnly, scene.sceneModel != nil else { return false }
        let sceneRevision = EditorAgentSceneToolService.revision(for: scene.content)
        let resourceRevision = library?.revision
        if let library, let resourceRevision {
            try library.checkRevision(resourceRevision)
            try library.requireSavedSnapshot()
        }
        let references = library.map { ["@res://" + String($0.url.path.dropFirst(service.assetsURL.path.count + 1))] } ?? []
        let documents = try service.savedDocuments(references: references, sceneURL: scene.absolutePath.map { URL(fileURLWithPath: $0) })
        let revisions = documents.map(\.revision)
        let candidate = Model3DSource(source: reference, animation: animation, autoplay: autoplay, repeats: repeats,
                                      animationGraph: graph, animationLibraries: references)
        let imported = try await service.animationsForModel(asset.relativePath)
        try Task.checkCancellation()
        _ = try candidate.resolvedAnimationClips(importedClips: imported.clips, rig: imported.rig, libraries: documents.map(\.library))
        for (document, revision) in zip(documents, revisions) {
            try document.checkRevision(revision)
            try document.requireSavedSnapshot()
        }
        if let library, let resourceRevision {
            try library.checkRevision(resourceRevision)
            try library.requireSavedSnapshot()
        }
        guard animationService === service, let current = sceneDocument(id: sceneID), !current.isReadOnly,
            EditorAgentSceneToolService.revision(for: current.content) == sceneRevision else {
            throw AnimationAuthoringError(.conflict, itemID: sceneID, message: "Scene or animation changed during placement; inspect and retry.")
        }
        return addModelAsset(asset, to: sceneID, animation: animation, autoplay: autoplay,
                             animationGraph: graph, animationLibraries: references, repeats: repeats)
    }


    func configureAnimationAuthoring(projectURL: URL, assetsURL: URL) {
        for workspace in animationWorkspaces.values { workspace.cancel() }
        animationWorkspaces.removeAll()
        animationService?.invalidatePendingWork()
        let service = EditorAnimationAuthoringService(projectURL: projectURL, assetsURL: assetsURL)
        animationService = service
        service.onDocumentOpened = { [weak self] document in self?.registerAnimationDocument(document, assetsURL: assetsURL) }
        service.onModifierDocumentOpened = { [weak self] document in self?.registerModifierDocument(document, assetsURL: assetsURL) }
        service.onModifierDocumentDiscarded = { [weak self] document in
            guard let self else { return }
            for workspace in self.animationWorkspaces.values where workspace.modifiers === document {
                workspace.cancelModifierDrag()
                workspace.refreshModifiers()
            }
        }
        service.onDocumentDiscarded = { [weak self] path in self?.discardDocuments(atOrBelow: path) }
    }

    private func registerAnimationDocument(_ document: EditorAnimationLibraryDocument, assetsURL: URL) {
        let documentID = "asset:\(document.relativePath)"
        document.onChange = { [weak self, weak document] in
            guard let self, let document,
                let index = self.openDocuments.firstIndex(where: { $0.id == documentID }), case .asset(var current) = self.openDocuments[index] else { return }
            current.isDirty = document.isDirty
            current.errorMessage = document.error
            self.openDocuments[index] = .asset(current)
            self.onDocumentEdited?(documentID)
        }
        if !openDocuments.contains(where: { $0.id == documentID }) {
            let asset = EditorAssetDocument(id: documentID, title: document.url.lastPathComponent, relativePath: document.relativePath,
                absolutePath: document.url.path, assetReference: "@res://" + String(document.url.path.dropFirst(assetsURL.path.count + 1)),
                kind: .animationLibrary, fileExtension: "animlib", byteCount: nil, modifiedAt: nil, errorMessage: nil, isDirty: document.isDirty)
            // Agent inspection does not replace the user's active scene or selection.
            openDocuments.append(.asset(asset))
        }
    }

    private func registerModifierDocument(_ document: EditorAnimationModifierDocument, assetsURL: URL) {
        let id = "asset:\(document.relativePath)"
        document.onChange = { [weak self, weak document] in
            guard let self, let document else { return }
            if let index = self.openDocuments.firstIndex(where: { $0.id == id }), case var .asset(asset) = self.openDocuments[index] {
                asset.isDirty = document.isDirty
                self.openDocuments[index] = .asset(asset)
            } else if document.isDirty {
                self.registerModifierDocument(document, assetsURL: assetsURL)
            }
            for workspace in self.animationWorkspaces.values where workspace.modifiers === document { workspace.refreshModifiers() }
            self.onDocumentEdited?(id)
        }
        if !openDocuments.contains(where: { $0.id == id }) {
            openDocuments.append(.asset(.init(id: id, title: document.url.lastPathComponent, relativePath: document.relativePath,
                absolutePath: document.url.path, assetReference: "@res://" + String(document.url.path.dropFirst(assetsURL.path.count + 1)),
                kind: .animationModifiers, fileExtension: "animmod", byteCount: nil, modifiedAt: nil, errorMessage: nil, isDirty: document.isDirty)))
        }
    }

    /// A resource tab and all model workspaces share ownership of a live draft.
    func releaseUnreferencedModifierDocuments() {
        guard let service = animationService else { return }
        let visible = Set(openDocuments.compactMap { value -> String? in
            if case let .asset(asset) = value, asset.kind == .animationModifiers { return asset.relativePath }; return nil
        })
        let attached = Set(animationWorkspaces.values.compactMap { $0.modifiers?.relativePath })
        for document in Array(service.modifierDocuments.values)
            where !document.isDirty && !visible.contains(document.relativePath) && !attached.contains(document.relativePath) {
            try? service.closeModifiers(document.relativePath)
        }
    }
}
