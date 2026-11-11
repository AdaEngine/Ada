import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Project build system switching", .serialized)
struct EditorBuildSystemSwitchTests {
    @Test("Changing the draft leaves the project intact and saving a missing manifest fails")
    func draftAndMissingManifest() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try ProjectSystem.loadProject(at: root)
        let editor = EditorViewModel(project: .init(name: "Game", path: root.path))
        let settings = EditorSettingsWindowViewModel(editorViewModel: editor, selectedSection: .project)

        settings.buildSystemBinding.wrappedValue = "swiftpm"
        #expect(try ProjectSystem.loadProject(at: root) == original)
        let reopened = EditorSettingsWindowViewModel(editorViewModel: editor, selectedSection: .project)
        #expect(reopened.buildSystemDraft == "adascript")

        settings.saveProjectSettings()
        #expect(editor.projectBuildSystemError != nil)
        #expect(try ProjectSystem.loadProject(at: root) == original)
    }

    @Test("Project Settings switches all targets and desktop Run starts the executable without a scene file")
    func savesAndRunsWithoutSceneFile() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "Game", targets: [.executableTarget(name: "Game", path: "Native")])
            """
        let manifestURL = root.appendingPathComponent("Package.swift")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        let native = root.appendingPathComponent("Native")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let code = """
            @main enum Game {
                static func main() { print("STUDIO_SWIFT_RUN_WITHOUT_SCENE") }
            }
            """
        try code.write(to: native.appendingPathComponent("Game.swift"), atomically: true, encoding: .utf8)
        let original = try ProjectSystem.loadProject(at: root)
        let editor = EditorViewModel(project: .init(name: "Game", path: root.path))
        let settings = EditorSettingsWindowViewModel(editorViewModel: editor, selectedSection: .project)
        editor.buildTargets.begin(original, product: nil)
        settings.buildSystemBinding.wrappedValue = "swiftpm"
        settings.saveProjectSettings()
        let switchTask = try #require(editor.workspaceTask)
        await switchTask.value
        await editor.workspaceTask?.value

        let saved = try ProjectSystem.loadProject(at: root)
        #expect(editor.projectBuildSystemError == nil)
        #expect(saved.build.system == .swiftpm)
        #expect(saved.buildTargets.map(\.id) == original.buildTargets.map(\.id))
        #expect(saved.activeBuildTargetID == original.activeBuildTargetID)
        #expect(saved.buildTargets.allSatisfy { $0.build.system == .swiftpm })
        #expect(saved.buildTargets.map(\.startupScene) == original.buildTargets.map(\.startupScene))
        #expect(editor.buildTargets.draft == nil)
        #expect(try String(contentsOf: manifestURL, encoding: .utf8) == manifest)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/Scenes/Main.ascn").path))
        editor.runSelectedTarget()
        let run = try #require(editor.workspaceTask, "\(editor.workspaceStatus.title)")
        await run.value
        #expect(editor.gameLogLines.contains { $0.text.contains("STUDIO_SWIFT_RUN_WITHOUT_SCENE") })
        #expect(editor.workspaceStatus == .ready)

        editor.presentNewFileDialog(kind: .swift)
        editor.newFileDestinationRelativePath = "Native"
        editor.newFileName = "NewSource"
        editor.workspaceTask = Task {}
        #expect(editor.createNewFile())
        #expect(editor.swiftPackageRefreshPending)
        editor.cancelWorkspaceCommand()
        let cancellation = try #require(editor.workspaceTask)
        await cancellation.value
        for _ in 0..<40 where editor.swiftPackageRefreshPending {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!editor.swiftPackageRefreshPending)
        await editor.workspaceTask?.value
        editor.projectSidebar.expandAll()
        #expect(editor.projectSidebar.visibleItems.contains { $0.relativePath == "Native/NewSource.swift" })

        settings.buildSystemBinding.wrappedValue = "adascript"
        settings.saveProjectSettings()
        await editor.workspaceTask?.value
        #expect(editor.projectBuildSystemError != nil)
        #expect(try ProjectSystem.loadProject(at: root) == saved)

        let scene = root.appendingPathComponent("Assets/Scenes/Main.ascn")
        try FileManager.default.createDirectory(at: scene.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SceneDocumentFormat.defaultSceneYAML(projectName: "Game").write(to: scene, atomically: true, encoding: .utf8)
        settings.saveProjectSettings()
        await editor.workspaceTask?.value
        await editor.workspaceTask?.value
        let restored = try ProjectSystem.loadProject(at: root)
        #expect(editor.projectBuildSystemError == nil)
        #expect(restored.build.system == .adaScript)
        #expect(restored.runtime.entry.scene == original.runtime.entry.scene)
        #expect(restored.buildTargets.allSatisfy { $0.build.system == .adaScript })
    }

    @Test("Multiple SwiftPM executables require a product selection before Run or manifest edits")
    func ambiguousProducts() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "Game", targets: [
                .executableTarget(name: "Game"), .executableTarget(name: "Tool")
            ])
            """
        let manifestURL = root.appendingPathComponent("Package.swift")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        for name in ["Game", "Tool"] {
            let folder = root.appendingPathComponent("Sources/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "print(\"\(name)\")".write(to: folder.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        }
        var project = try ProjectSystem.loadProject(at: root)
        project.setBuildSystem(.swiftpm)
        try ProjectSystem.saveProject(project, at: root)
        let result = await SwiftPMWorkspaceService().execute(.describe, projectURL: root)
        let package = try #require(SwiftPackageModel.parse(from: result.standardOutput), "\(result.combinedOutput)")
        let editor = EditorViewModel(project: .init(name: "Game", path: root.path), packageModel: package)
        editor.projectIncludedFiles = ["Sources/Game"]
        editor.saveProjectSettings()
        #expect(editor.selectedRunTargetName == nil)
        #expect(try String(contentsOf: manifestURL, encoding: .utf8) == manifest)
        editor.runSelectedTarget()
        #expect(editor.workspaceTask == nil)
        #expect(editor.buildTargets.isPresented)
    }

    @Test("Targets stays available when a SwiftPM dependency cannot be resolved")
    func localTargetsSurviveResolutionFailure() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = root.appendingPathComponent("Native")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try "print(1)".write(to: native.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let manifest = """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "Game", dependencies: [.package(path: "Missing")],
                targets: [.executableTarget(name: "Game", path: "Native")])
            """
        try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        var project = try ProjectSystem.loadProject(at: root)
        project.setBuildSystem(.swiftpm)
        try ProjectSystem.saveProject(project, at: root)
        let editor = EditorViewModel(project: .init(name: "Game", path: root.path))
        editor.bootstrapWorkspaceIfNeeded()
        await editor.workspaceTask?.value
        editor.projectSidebar.expandAll()
        #expect(editor.projectSidebar.visibleItems.contains { $0.relativePath == "Native/main.swift" })
        guard case .failed = editor.workspaceStatus else {
            Issue.record("The missing dependency should still fail workspace resolution.")
            return
        }
    }

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioBuildSystem-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "class Shared {}".write(to: sources.appendingPathComponent("Main.ada"), atomically: true, encoding: .utf8)
        var project = ProjectSystem.defaultProject(projectName: "Game", buildSystem: .adaScript)
        #if os(Windows)
            project.run.destination = .windows
        #elseif os(Linux)
            project.run.destination = .linux
        #endif
        project.ensureBuildTargets(defaultName: "Main")
        project.buildTargets.append(AdaProjectBuildTarget(name: "Test", project: project))
        try ProjectSystem.saveProject(project, at: root)
        return root
    }
}
