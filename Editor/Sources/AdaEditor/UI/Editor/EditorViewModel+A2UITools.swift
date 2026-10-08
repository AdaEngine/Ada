import Foundation

extension EditorViewModel {
    func applyChatTool(_ request: EditorAgentA2UIToolRequest) throws -> EditorAgentA2UIToolResult {
        let path = try request.string("path")
        guard let document = workbench.openDocuments.compactMap({ item -> EditorSceneDocument? in
            guard case let .scene(scene) = item, scene.relativePath == path else {
                return nil
            }
            return scene
        }).first, !document.isReadOnly, let source = document.sceneModel, let projectURL else {
            throw EditorAgentA2UIToolRequest.Failure("Open the target scene in this project before applying the card.")
        }
        let revision = EditorAgentSceneToolService.revision(for: document.content)
        let expected = try request.string("expectedRevision")
        guard revision == expected else { throw EditorAgentSceneToolError.revisionConflict(expected: expected, actual: revision) }
        let service = EditorAgentSceneToolService(projectURL: projectURL)
        let model = try service.applying(operations: request.operations(in: source), to: source)
        var before = source
        var after = model
        before.editor = nil
        after.editor = nil
        guard before != after else {
            throw EditorAgentA2UIToolRequest.Failure("The tool made no scene changes.")
        }
        var updated = document
        updated.sceneModel = model
        updated.content = try model.encodedYAML()
        updated.loadSummary = EditorSceneFileLoader.summary(from: updated.content)
        updated.isDirty = updated.content != updated.lastSavedContent
        updated.statusMessage = "Applied chat tool"
        workbench.replaceSceneDocument(updated)
        return .init(path: path, revision: EditorAgentSceneToolService.revision(for: updated.content), changeID: nil, message: "Applied to \(path)")
    }

    func undoChatTool(_ result: EditorAgentA2UIToolResult) throws -> String {
        guard let document = workbench.activeSceneDocument, document.relativePath == result.path else {
            throw EditorAgentA2UIToolRequest.Failure("Select \(result.path) before undoing this card.")
        }
        let revision = EditorAgentSceneToolService.revision(for: document.content)
        guard revision == result.revision else { throw EditorAgentSceneToolError.undoConflict(expected: result.revision, actual: revision) }
        guard workbench.performDocumentHistory(redo: false), let restored = workbench.activeSceneDocument else {
            throw EditorAgentA2UIToolRequest.Failure("The scene's undo history is unavailable. Use the editor's scene history.")
        }
        return EditorAgentSceneToolService.revision(for: restored.content)
    }
}
