import AdaEngine
import Foundation

extension EditorAnimationAuthoringService {
    /// Common transport adapter for agent calls and generation-scoped Tool jobs.
    func execute(_ request: AnimationAuthoringRequest, workbench: EditorWorkbenchViewModel) async throws -> [String: Any] {
        let generation = requestGeneration()
        let offset = request.offset ?? 0
        let limit = request.limit ?? 128
        guard offset >= 0, (1...256).contains(limit) else { throw invalidRequest("offset >= 0 and limit in 1...256 are required.") }
        try Task.checkCancellation()
        if request.action.isGraphAction { return try await executeGraph(request, workbench: workbench) }
        if request.action.isModifierAction { return try await executeModifiers(request, workbench: workbench) }
        if request.action == .discard {
            guard let document = documents.values.first(where: { $0.relativePath == request.path }) else { throw invalidRequest("Open draft was not found.") }
            try discard(document, expectedRevision: request.expectedRevision ?? "", discardChanges: request.discardChanges == true)
            return ["path": request.path, "discarded": true]
        }
        if request.action == .create || request.action == .extract {
            guard let modelPath = request.modelPath, request.action != .extract || request.sourceClip != nil else {
                throw invalidRequest("A modelPath and, for extraction, sourceClip are required.")
            }
            let document = try await extract(path: request.path, modelPath: modelPath,
                clipName: request.action == .create ? nil : request.sourceClip, name: request.name, expectedRevision: request.expectedRevision)
            var result = acknowledgement(document)
            result["createdClipID"] = document.library.clips.last?.id ?? ""
            return result
        }
        let document = try open(request.path)
        if let expected = request.expectedRevision { try document.checkRevision(expected) }
        switch request.action {
        case .modifierInspect, .modifierCreate, .modifierApply, .modifierSample, .modifierSave, .modifierUndo, .modifierRedo,
             .modifierPreview, .modifierBind, .modifierReload, .modifierDiscard: break
        case .graphInspect, .graphApply, .graphPreview, .graphUndo, .graphRedo, .graphBind: break
        case .create, .extract: break
        case .inspect: break
        case .apply:
            guard let operations = request.operations else { throw invalidRequest("operations are required.") }
            try document.checkEditableRevision(request.expectedRevision ?? "")
            let draft = try await Self.editedLibrary(document.library, operations: operations)
            try Task.checkCancellation()
            try checkGeneration(generation)
            try document.commit(draft, expectedRevision: request.expectedRevision ?? "")
        case .capture:
            guard let source = request.clipID else { throw invalidRequest("clipID is required.") }
            try document.checkRevision(request.expectedRevision ?? "")
            let revision = document.revision
            let player = try await Self.sampledPlayer(document.library, clipID: source, time: request.time ?? 0)
            try Task.checkCancellation()
            try checkGeneration(generation)
            try document.checkRevision(revision)
            let clip = try document.library.poseClip(name: request.name ?? "Captured pose", duration: request.duration ?? 1, from: player)
            try document.apply([.init(kind: .createClip, clip: clip)], expectedRevision: request.expectedRevision ?? "")
            var result = acknowledgement(document)
            result["createdClipID"] = clip.id
            return result
        case .sample:
            guard let clipID = request.clipID else { throw invalidRequest("clipID is required.") }
            let revision = document.revision
            let player = try await Self.sampledPlayer(document.library, clipID: clipID, time: request.time ?? 0)
            try Task.checkCancellation()
            try checkGeneration(generation)
            try document.checkRevision(revision)
            let end = min(player.poses.count, offset + min(limit, Int.max - offset))
            let indices = offset < end ? Array(offset..<end) : []
            return ["path": document.relativePath, "revision": document.revision, "clipID": clipID, "rendered": false,
                "offset": offset, "total": player.poses.count,
                "poses": indices.map { index -> [String: Any] in
                    let pose = player.poses[index]
                    return ["nodeID": document.library.binding.nodes[index].id,
                        "hasTRS": document.library.binding.nodes[index].restTranslation != nil,
                        "localMatrixColumnMajor": matrixValues(player.localTransforms[index]),
                        "globalMatrixColumnMajor": matrixValues(player.globalTransforms[index]),
                        "translation": [pose.translation.x, pose.translation.y, pose.translation.z],
                        "rotation": [pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w],
                        "scale": [pose.scale.x, pose.scale.y, pose.scale.z], "morphWeights": player.morphWeights[index]]
                }]
        case .validate:
            try document.library.validate()
            if let modelPath = request.modelPath {
                let revision = document.revision
                let rig = try await rigForModel(modelPath)
                try Task.checkCancellation()
                try document.checkRevision(revision)
                _ = try document.library.compiledClips(for: rig)
            }
            return ["path": document.relativePath, "revision": document.revision, "schemaValid": true,
                "rigCompatibilityChecked": request.modelPath != nil, "rendered": false]
        case .save: try document.save(expectedRevision: request.expectedRevision ?? "")
        case .undo: try document.undo(expectedRevision: request.expectedRevision ?? "")
        case .redo: try document.redo(expectedRevision: request.expectedRevision ?? "")
        case .reload: try reload(document, expectedRevision: request.expectedRevision ?? "", discardChanges: request.discardChanges == true)
        case .discard: break
        case .bind:
            guard let scenePath = request.scenePath, let entityID = request.entityID, let sceneRevision = request.sceneRevision,
                let clipID = request.clipID, let scene = workbench.openDocuments.compactMap({ value -> EditorSceneDocument? in
                    if case let .scene(scene) = value, scene.relativePath == scenePath { return scene }
                    return nil
                }).first else { throw invalidRequest("Open scenePath, entityID, sceneRevision and clipID are required.") }
            try await workbench.bindAnimationLibrary(document, sceneID: scene.id, entityID: entityID,
                expectedSceneRevision: sceneRevision, expectedResourceRevision: request.expectedRevision ?? "", clipID: clipID)
        case .preview:
            for workspace in workbench.animationWorkspaces.values where workspace.library === document {
                try workspace.requireNoUnkeyedPose()
            }
            guard let clipID = request.clipID, document.library.clips.contains(where: { $0.id == clipID }),
                (request.time ?? 0).isFinite else { throw invalidRequest("A valid clipID and finite preview time are required.") }
            document.selectedClipID = clipID
            document.previewTime = request.time ?? 0
            document.previewSerial &+= 1
            workbench.selectDocument(id: "asset:\(document.relativePath)")
            return ["path": document.relativePath, "revision": document.revision, "previewRequested": true, "renderVerified": false,
                "verification": "Wait for the library viewport to load, then capture the editor; use visible Play for game-camera proof."]
        }
        if request.action.writesResource || request.action == .bind { return acknowledgement(document) }
        return try snapshot(document, clipID: request.clipID, trackID: request.trackID, offset: offset, limit: limit)
    }

    private func matrixValues(_ matrix: Transform3D) -> [Float] {
        (0..<4).flatMap { column in (0..<4).map { row in matrix[column, row] } }
    }

    @concurrent
    private static func editedLibrary(_ library: AnimationLibrary, operations: [AnimationEdit]) async throws -> AnimationLibrary {
        try Task.checkCancellation()
        var draft = library
        try draft.apply(operations)
        try Task.checkCancellation()
        return draft
    }

    @concurrent
    private static func sampledPlayer(_ library: AnimationLibrary, clipID: String, time: Double) async throws -> SkeletalAnimationPlayer {
        try Task.checkCancellation()
        return try library.sample(clipID: clipID, at: time)
    }

    /// Mutation acknowledgements are independent of page/selection fields, so a committed edit cannot
    /// be reported as failed because a requested inspection page exceeds the transport budget.
    private func acknowledgement(_ document: EditorAnimationLibraryDocument) -> [String: Any] {
        ["path": document.relativePath, "revision": document.revision, "dirty": document.isDirty,
         "libraryID": document.library.id, "clipCount": document.library.clips.count]
    }

    static func responseData(_ payload: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= 1_048_576 else {
            throw AnimationAuthoringError(.limitExceeded, itemID: "response", message: "Response exceeds 1 MiB; request a smaller page.")
        }
        return data
    }

    private func snapshot(_ document: EditorAnimationLibraryDocument, clipID: String?, trackID: String?, offset: Int, limit: Int) throws -> [String: Any] {
        let library = document.library
        var payload: [String: Any] = ["path": document.relativePath, "revision": document.revision, "dirty": document.isDirty,
            "libraryID": library.id, "sourceAsset": library.binding.sourceAsset, "nodeCount": library.binding.nodes.count,
            "limits": ["nodes": 16_384, "clips": 256, "tracksPerClip": 4_096, "keys": 100_000, "operationsPerBatch": 256, "pageSize": 256],
            "clipCount": library.clips.count,
            "clips": library.clips.dropFirst(offset).prefix(limit).map { ["id": $0.id, "name": $0.name, "duration": $0.duration, "repeats": $0.repeats,
                "runtimeName": library.runtimeName(for: $0.id), "trackCount": $0.tracks.count] as [String: Any] }]
        if let clipID {
            guard let clip = library.clips.first(where: { $0.id == clipID }) else { throw invalidRequest("clipID was not found.") }
            payload["tracks"] = clip.tracks.dropFirst(offset).prefix(limit).map { track in
                ["id": track.id, "nodeID": track.nodeID, "channel": track.channel.rawValue,
                 "interpolation": track.interpolation.rawValue, "keyCount": track.keys.count] as [String: Any]
            }
            if let trackID {
                guard let track = clip.tracks.first(where: { $0.id == trackID }) else { throw invalidRequest("trackID was not found.") }
                payload["keys"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(track.keys.dropFirst(offset).prefix(limit))))
                payload["keyCount"] = track.keys.count
            }
        } else {
            payload["nodes"] = library.binding.nodes.dropFirst(offset).prefix(limit).map {
                ["id": $0.id, "name": $0.name ?? "", "parentID": $0.parentID ?? "", "hasTRS": $0.restTranslation != nil,
                 "morphTargetCount": $0.morphRestWeights?.count ?? 0] as [String: Any]
            }
        }
        return payload
    }

    private func invalidRequest(_ message: String) -> AnimationAuthoringError { .init(.invalidTrack, itemID: "request", message: message) }
}
