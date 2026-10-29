import Foundation
import Testing

@testable import AdaEditor

@Suite("Selection encoding")
@MainActor
struct EditorSelectionEncodingTests {
    @Test("Selecting and saving preserves large payload bytes")
    func selectionAndSave() throws {
        var model = EditorSceneModel.default(projectName: "Selection")
        let rootID = try #require(model.rootEntityID)
        let child = model.addEntity(name: "Child", parentID: rootID)
        model.entities[0].components["FixtureData"] = ["vertices": .array((0..<30_000).map { .int($0) })]
        let yaml = try model.encodedYAML()
        let content = yaml.replacingOccurrences(of: "entities:\n", with: "# Keep authored formatting\nentities:\n")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Scene.ascn")
        try content.write(to: file, atomically: true, encoding: .utf8)
        let document = EditorSceneDocument(id: "scene", title: "Scene.ascn", relativePath: "Scene.ascn", absolutePath: file.path,
                                           content: content, lastSavedContent: content, sceneModel: model, isDirty: false, statusMessage: "Loaded",
                                           loadSummary: .init(entityCount: model.entities.count, warnings: []))
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        workbench.selectSceneEntity(documentID: document.id, entityID: rootID)
        workbench.toggleSceneEntityExpanded(documentID: document.id, entityID: rootID)
        let selected = try #require(workbench.activeSceneDocument)
        let originalPrefix = try #require(content.range(of: "\neditor:"))
        let updatedPrefix = try #require(selected.content.range(of: "\neditor:"))
        #expect(content[..<originalPrefix.lowerBound] == selected.content[..<updatedPrefix.lowerBound])
        #expect(EditorSceneModel.onlyEditorStateChanged(from: content, to: selected.content))
        #expect(!EditorSceneModel.onlyEditorStateChanged(from: content.replacingOccurrences(of: "Keep authored formatting", with: "Other"), to: selected.content))
        #expect(selected.sceneModel?.editor?.selectedEntity == rootID)
        #expect(workbench.sceneUndoHistory[document.id] == nil)
        #expect(workbench.saveSceneDocument(id: document.id))
        let reopened = try EditorSceneModel.decode(from: String(contentsOf: file, encoding: .utf8))
        #expect(reopened.entities == model.entities)
        #expect(reopened.editor == selected.sceneModel?.editor)
        #expect(reopened.entities.contains { $0.id == child.id })
    }

    @Test("Noncanonical documents keep selection and authored fields through the full encoder", arguments: [false, true])
    func fallback(json: Bool) throws {
        var model = EditorSceneModel.default(projectName: "Fallback")
        let content = try json ? String(decoding: JSONEncoder().encode(model), as: UTF8.self) : model.encodedYAML() + "engineVersion: 1.0.0\n"
        model.selectEntity(nil)
        let output = try model.encodedYAML(updatingEditorStateIn: content)
        #expect(try EditorSceneModel.decode(from: output) == model)
    }
}
