import Foundation
import Testing

@testable import AdaEditor

@Suite("Studio source control workflow", .enabled(if: EditorSourceControlProvider.lore.isAvailable))
@MainActor
struct EditorSourceControlWorkflowTests {
    @Test("Project creation initializes the selected provider and reopens with it")
    func createLoreProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Studio-Lore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"), distribution: .standalone)
        let opening = ProjectOpeningViewModel(store: store)
        opening.projectName = "Lore Game"
        opening.projectLocation = root.path
        opening.selectedTemplate = .adaScript
        #expect(opening.newProjectSourceControl == .lore)
        opening.createProject(openInEditor: true)
        await opening.repositoryCreationTask?.value
        let project = try #require(opening.projectToOpenInEditor)
        let url = URL(fileURLWithPath: project.path, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(".lore").path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path))
        #expect(EditorSourceControlProvider.load(in: url) == .lore)
        let editor = EditorViewModel(project: project)
        #expect(editor.sourceControl.provider == .lore)
        editor.refreshSourceControl()
        await editor.sourceControl.refreshTask?.value
        #expect(editor.sourceControl.snapshot.provider == .lore)
        #expect(editor.sourceControl.snapshot.rootURL == url)
        editor.sourceControl.isRunning = true
        editor.selectSourceControlProvider(.git)
        #expect(editor.sourceControl.provider == .lore)
        editor.sourceControl.isRunning = false
        editor.selectSourceControlProvider(.git)
        await editor.sourceControl.refreshTask?.value
        #expect(EditorSourceControlProvider.load(in: url) == .git)
        #expect(editor.sourceControl.commits.isEmpty)
        #expect(editor.sourceControl.documents.isEmpty)
    }
}
