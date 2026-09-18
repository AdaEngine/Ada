import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor project persistence")
struct EditorProjectPersistenceTests {
    @Test("view model restores an app-owned project after the data container UUID changes")
    @MainActor
    func projectOpeningViewModelRestoresProjectAfterContainerMigration() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorProjectContainerMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let currentDocumentsURL = rootURL.appendingPathComponent("Current/Documents", isDirectory: true)
        let storageURL = rootURL.appendingPathComponent("Application Support/AdaEditor/projects.json")
        let store = EditorProjectStore(
            storageURL: storageURL,
            documentsDirectoryURL: currentDocumentsURL
        )
        let project = try store.createProject(
            named: "Migrated Game",
            at: currentDocumentsURL,
            template: .adaScript
        )
        let stalePath =
            rootURL
            .appendingPathComponent("Containers/Data/Application/OLD-CONTAINER/Documents", isDirectory: true)
            .appendingPathComponent("Migrated-Game.adaproject", isDirectory: true)
            .path
        try store.saveProjects([
            EditorProjectReference(
                id: project.id,
                name: project.name,
                path: stalePath,
                lastOpenedAt: project.lastOpenedAt
            )
        ])

        let restoredProject = try #require(store.loadProjects().first)
        let viewModel = ProjectOpeningViewModel(store: store)
        let didOpen = await viewModel.openLastProjectIfAvailable()

        #expect(restoredProject.path == project.path)
        #expect(restoredProject.documentsRelativePath == "Migrated-Game.adaproject")
        #expect(didOpen)
        #expect(viewModel.projectToOpenInEditor?.path == project.path)
    }
}
