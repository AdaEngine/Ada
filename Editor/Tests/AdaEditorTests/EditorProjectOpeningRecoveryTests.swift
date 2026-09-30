import Foundation
import Testing

@testable import AdaEditor

@Suite("Project opening recovery")
struct EditorProjectOpeningRecoveryTests {
    @Test("Opening a portable project creates metadata without changing scripts or scenes")
    @MainActor
    func initializesPortableProject() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Sources/Game.ada")
        let sceneURL = root.appendingPathComponent("Assets/Scenes/Existing.ascn")
        let source = "// Existing game code\n"
        let scene = try EditorSceneModel.default(projectName: "Existing").encodedYAML()
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try scene.write(to: sceneURL, atomically: true, encoding: .utf8)
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recent.json"))
        let model = ProjectOpeningViewModel(store: store)
        model.openProject(at: root)

        #expect(model.projectToOpenInEditor?.path == root.standardizedFileURL.path)
        #expect(model.validationDiagnostics.isEmpty)
        let project = try ProjectSystem.loadProject(at: root)
        #expect(project.build.system == .adaScript)
        #expect(project.runtime.entry.scene == "Assets/Scenes/Existing.ascn")
        #expect(project.runtime.entry.view == nil)
        _ = try EditorAdaScriptProjectBuilder().prepare(project: project, at: root)
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == source)
        #expect(try String(contentsOf: sceneURL, encoding: .utf8) == scene)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
    }

    @Test("Unreadable existing metadata stays a read error and is never replaced")
    func doesNotOverwriteUnreadableMetadata() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ProjectSystem.metadataURL(forProjectAt: root)
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Keep", buildSystem: .adaScript), at: root)
        let original = try Data(contentsOf: metadata)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: metadata.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path) }
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recent.json"))
        do {
            _ = try store.openProject(at: root)
            Issue.record("Unreadable metadata was accepted")
        } catch let error as ProjectSystemError {
            guard case .fileReadFailed = error else { throw error }
            #expect(error.recoverySuggestion.contains("Open Project"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        #expect(try Data(contentsOf: metadata) == original)
    }

    @Test("Invalid metadata is preserved instead of replaced by defaults")
    func doesNotOverwriteInvalidMetadata() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ProjectSystem.metadataURL(forProjectAt: root)
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ broken JSON".utf8)
        try original.write(to: metadata)
        let store = EditorProjectStore(storageURL: root.appendingPathComponent("recent.json"))
        #expect(throws: (any Error).self) { try store.openProject(at: root) }
        #expect(try Data(contentsOf: metadata) == original)
    }

    @Test("Metadata initialization never replaces a file another open already created")
    func preservesMetadataDuringRepeatedInitialization() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectSystem.defaultProject(projectName: "Original", buildSystem: .adaScript)
        try ProjectSystem.saveProject(project, at: root)
        let original = try Data(contentsOf: ProjectSystem.metadataURL(forProjectAt: root))
        let loaded = try ProjectSystem.createProjectIfMissing(
            ProjectSystem.defaultProject(projectName: "Replacement", buildSystem: .adaScript),
            at: root,
            fileManager: .default
        )
        #expect(loaded.project.name == "Original")
        #expect(try Data(contentsOf: ProjectSystem.metadataURL(forProjectAt: root)) == original)
    }

    #if os(macOS)
        @Test("Desktop project references persist and resolve a real security-scoped bookmark")
        func desktopBookmarkSurvivesStoredPathChange() throws {
            let root = try temporaryProject()
            defer { try? FileManager.default.removeItem(at: root) }
            try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Bookmarked", buildSystem: .adaScript), at: root)
            let store = EditorProjectStore(storageURL: root.appendingPathComponent("recent.json"))
            var reference = try store.openProject(at: root)
            #expect(reference.bookmarkData != nil)
            let reopened = try store.openProject(at: store.resolveProjectURL(for: reference))
            #expect(reopened.id == reference.id)
            #expect(reopened.path == reference.path)
            #expect(try store.loadProjects().count == 1)
            reference.path = root.appendingPathComponent("obsolete-path").path
            try store.saveProjects([reference])
            let reloaded = try #require(store.loadProjects().first)
            #expect(URL(fileURLWithPath: reloaded.path).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
            let resolved = store.resolveProjectURL(for: reloaded)
            #expect(try ProjectSystem.loadProject(at: resolved).project.name == "Bookmarked")
        }
    #endif

    private func temporaryProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectOpeningRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/Scenes"), withIntermediateDirectories: true)
        return root
    }
}
