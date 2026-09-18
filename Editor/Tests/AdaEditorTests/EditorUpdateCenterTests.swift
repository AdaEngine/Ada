import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor update restart protection")
@MainActor
struct EditorUpdateCenterTests {
    @Test func savesEveryOpenWorkspaceBeforeRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "".write(to: root.appendingPathComponent("first.ada"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("second.ada"), atomically: true, encoding: .utf8)
        let center = EditorUpdateCenter()
        let first = workbench(path: root.appendingPathComponent("first.ada"), content: "first edit")
        let second = workbench(path: root.appendingPathComponent("second.ada"), content: "second edit")
        center.register(first)
        center.register(second)
        #expect(center.saveBeforeRestart())
        #expect(try String(contentsOf: root.appendingPathComponent("first.ada"), encoding: .utf8) == "first edit")
        #expect(try String(contentsOf: root.appendingPathComponent("second.ada"), encoding: .utf8) == "second edit")
        #expect(first.activeDocument?.isDirty == false)
        #expect(second.activeDocument?.isDirty == false)
    }

    @Test func failedSaveBlocksRestartAndCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = EditorUpdateCenter()
        // Attempting to replace a directory with a document deterministically fails.
        let model = workbench(path: root, content: "unsaved edit")
        center.register(model)
        #expect(!center.saveBeforeRestart())
        #expect(model.activeDocument?.isDirty == true)
        #expect(center.errorMessage != nil)
        try "".write(to: root.appendingPathComponent("recovered.ada"), atomically: true, encoding: .utf8)
        model.updateTextDocument(id: "document") { document in
            document.absolutePath = root.appendingPathComponent("recovered.ada").path
        }
        #expect(center.saveBeforeRestart())
        #expect(try String(contentsOf: root.appendingPathComponent("recovered.ada"), encoding: .utf8) == "unsaved edit")
    }

    @Test func closedWorkspacesAreNotRetained() {
        let center = EditorUpdateCenter()
        weak var released: EditorWorkbenchViewModel?
        do {
            let model = EditorWorkbenchViewModel(openDocuments: [], activeDocumentID: "")
            released = model
            center.register(model)
        }
        #expect(released == nil)
        #expect(center.saveBeforeRestart())
    }

    private func workbench(path: URL, content: String) -> EditorWorkbenchViewModel {
        let document = EditorTextDocument(
            id: "document",
            title: "Main.ada",
            relativePath: "Main.ada",
            absolutePath: path.path,
            language: .ada,
            content: content,
            lastSavedContent: "",
            isDirty: true
        )
        return EditorWorkbenchViewModel(openDocuments: [.text(document)], activeDocumentID: document.id)
    }
}
