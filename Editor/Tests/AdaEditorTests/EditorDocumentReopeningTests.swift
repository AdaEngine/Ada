import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Project document reopening")
struct EditorDocumentReopeningTests {
    @Test("Reopening an edited file preserves edits and detects an external write when saving")
    func reopeningPreservesEdits() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let viewModel = fixture.viewModel
        viewModel.openProjectItem(fixture.item)
        let id = viewModel.workbench.activeDocumentID
        #expect(!id.isEmpty)
        viewModel.workbench.textDocumentBinding(documentID: id).wrappedValue = "// Unsaved edit\n"
        try "// External write\n".write(to: fixture.file, atomically: true, encoding: .utf8)

        viewModel.openProjectItem(fixture.item)

        let document = try #require(viewModel.workbench.textDocument(id: id))
        #expect(document.content == "// Unsaved edit\n")
        #expect(document.lastSavedContent == "// Original\n")
        #expect(document.isDirty)
        #expect(viewModel.workbench.openDocuments.count == 1)
        #expect(viewModel.workbench.saveActiveDocument() == false)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "// External write\n")
        #expect(viewModel.workbench.textDocument(id: id)?.content == "// Unsaved edit\n")
    }

    @Test("Raw and ordinary tabs remain distinct when opening the same file again")
    func rawTabDoesNotReplaceOrdinaryTab() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let viewModel = fixture.viewModel
        viewModel.openProjectItem(fixture.item)
        let normalID = viewModel.workbench.activeDocumentID
        viewModel.openProjectItemAsRaw(fixture.item)
        #expect(viewModel.workbench.activeDocumentID != normalID)
        viewModel.openProjectItem(fixture.item)
        #expect(viewModel.workbench.activeDocumentID == normalID)
        #expect(viewModel.workbench.openDocuments.count == 2)
    }

    @Test("A clean tab refreshes external changes when reopened from the tree")
    func reopeningCleanFileRefreshesDiskChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.viewModel.openProjectItem(fixture.item)
        try "// Updated externally\n".write(to: fixture.file, atomically: true, encoding: .utf8)
        fixture.viewModel.openProjectItem(fixture.item)
        let id = fixture.viewModel.workbench.activeDocumentID
        #expect(fixture.viewModel.workbench.textDocument(id: id)?.content == "// Updated externally\n")
        #expect(fixture.viewModel.workbench.textDocument(id: id)?.isDirty == false)
    }

    @Test("Reopening retries an unreadable file after its UTF-8 contents are repaired")
    func reopeningRetriesReadFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data([0xFF, 0xFE, 0x80]).write(to: fixture.file)
        fixture.viewModel.openProjectItem(fixture.item)
        let id = fixture.viewModel.workbench.activeDocumentID
        #expect(fixture.viewModel.workbench.textDocument(id: id)?.errorMessage != nil)
        try "// Repaired\n".write(to: fixture.file, atomically: true, encoding: .utf8)
        fixture.viewModel.openProjectItem(fixture.item)
        let document = try #require(fixture.viewModel.workbench.textDocument(id: id))
        #expect(document.content == "// Repaired\n")
        #expect(document.errorMessage == nil)
        #expect(document.isReadOnly == false)
    }

    @Test("Reopening unchanged scene bytes preserves the prepared scene and load warnings")
    func reopeningUnchangedScenePreservesPreparation() throws {
        let model = EditorSceneModel.default(projectName: "Prepared")
        let fixture = try Fixture(fileName: "Scene.ascn", content: model.encodedYAML())
        defer { fixture.remove() }
        fixture.viewModel.openProjectItem(fixture.item)
        let id = fixture.viewModel.workbench.activeDocumentID
        fixture.viewModel.workbench.updateSceneDocument(id: id) { document in
            document.loadSummary.warnings = ["Optional texture is missing"]
        }
        fixture.viewModel.openProjectItem(fixture.item)
        let document = try #require(fixture.viewModel.workbench.sceneDocument(id: id))
        #expect(document.sceneModel == model)
        #expect(document.loadSummary.warnings == ["Optional texture is missing"])
        #expect(document.isLoading == false)
        #expect(document.isDirty == false)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let file: URL
        let viewModel: EditorViewModel
        let item: EditorProjectSidebarViewModel.Item

        init(fileName: String = "Example.ada", content: String = "// Original\n") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioReopen-\(UUID())", isDirectory: true)
            let sources = root.appendingPathComponent("Sources", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            file = sources.appendingPathComponent(fileName)
            try content.write(to: file, atomically: true, encoding: .utf8)
            try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Reopen", buildSystem: .adaScript), at: root)
            viewModel = EditorViewModel(project: .init(name: "Reopen", path: root.path))
            item = try #require(viewModel.projectSidebar.items.first { $0.relativePath == "Sources/\(fileName)" })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
