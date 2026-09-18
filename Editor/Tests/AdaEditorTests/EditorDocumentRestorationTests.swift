import Foundation
import Testing

@testable import AdaEditor

@Suite("Project document restoration")
@MainActor
struct EditorDocumentRestorationTests {
    @Test("First opening selects the configured main scene")
    func opensMainScene() throws {
        let (root, project) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = URL(fileURLWithPath: project.path)
        let main = projectURL.appendingPathComponent("Assets/Scenes/Main.ascn")
        let custom = projectURL.appendingPathComponent("Assets/Scenes/Entry.ascn")
        try FileManager.default.copyItem(at: main, to: custom)
        var metadata = try ProjectSystem.loadProject(at: projectURL)
        metadata.runtime.entry.scene = "Assets/Scenes/Entry.ascn"
        metadata.editor.startupScene = "Assets/Scenes/Entry.ascn"
        try ProjectSystem.saveProject(metadata, at: projectURL)
        let model = EditorViewModel(project: project)
        #expect(model.workbench.activeDocument?.relativePath == "Assets/Scenes/Entry.ascn")
        #expect(model.projectSidebar.selectedItem?.relativePath == "Assets/Scenes/Entry.ascn")
    }

    @Test("Reopening restores the active tab, independently for each project")
    func restoresLastActiveFile() throws {
        let (root, project) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = URL(fileURLWithPath: project.path).appendingPathComponent("note.txt")
        try "note".write(to: file, atomically: true, encoding: .utf8)
        let model = EditorViewModel(project: project)
        let sceneID = try #require(model.workbench.activeDocument?.id)
        let item = try #require(model.projectSidebar.items.first { $0.relativePath == "note.txt" })
        model.openProjectItem(item)
        #expect(EditorViewModel(project: project).workbench.activeDocument?.relativePath == "note.txt")
        model.workbench.selectDocument(id: sceneID)
        #expect(EditorViewModel(project: project).workbench.activeDocument?.relativePath == "Assets/Scenes/Main.ascn")
        let other = try EditorProjectStore(storageURL: root.appendingPathComponent("other.json"))
            .createProject(named: "Other", at: root)
        #expect(EditorViewModel(project: other).workbench.activeDocument?.relativePath == "Assets/Scenes/Main.ascn")
    }

    @Test("Deleted last file and damaged session fall back to the main scene")
    func fallsBackToScene() throws {
        let (root, project) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = URL(fileURLWithPath: project.path)
        let file = projectURL.appendingPathComponent("note.txt")
        try "note".write(to: file, atomically: true, encoding: .utf8)
        let model = EditorViewModel(project: project)
        model.openProjectItem(try #require(model.projectSidebar.items.first { $0.relativePath == "note.txt" }))
        try FileManager.default.removeItem(at: file)
        #expect(EditorViewModel(project: project).workbench.activeDocument?.relativePath == "Assets/Scenes/Main.ascn")
        try "invalid".write(to: projectURL.appendingPathComponent(".ada/workspace/editor-session.json"), atomically: true, encoding: .utf8)
        #expect(EditorViewModel(project: project).workbench.activeDocument?.relativePath == "Assets/Scenes/Main.ascn")
    }

    private func makeProject() throws -> (URL, EditorProjectReference) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try EditorProjectStore(storageURL: root.appendingPathComponent("projects.json"))
            .createProject(named: "Test", at: root)
        return (root, project)
    }
}
