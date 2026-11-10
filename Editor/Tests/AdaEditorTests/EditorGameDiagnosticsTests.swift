import Foundation
import Testing

@testable import AdaEditor

@Suite("Game diagnostics launch settings")
@MainActor
struct EditorGameDiagnosticsTests {
    @Test func draftAndSavedTargetsKeepIndependentValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GameDiagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = ProjectSystem.defaultProject(projectName: "Game", buildSystem: .adaScript)
        try ProjectSystem.saveProject(legacy, at: root)
        let original = try ProjectSystem.loadProject(at: root)
        #expect(!original.run.diagnosticsOverlay)

        let model = EditorBuildTargetsModel()
        model.begin(original, product: nil)
        let mainID = try #require(model.editedTarget?.id)
        model.edit { $0.run.diagnosticsOverlay = true }
        #expect(try ProjectSystem.loadProject(at: root) == original)
        model.add(copy: true)
        let duplicateID = try #require(model.editedTarget?.id)
        #expect(model.editedTarget?.run.diagnosticsOverlay == true)
        model.add()
        let freshID = try #require(model.editedTarget?.id)
        #expect(model.editedTarget?.run.diagnosticsOverlay == false)
        model.select(mainID)
        var saved = try #require(model.draft)
        try ProjectSystem.saveProject(saved, at: root)
        saved = try ProjectSystem.loadProject(at: root)
        #expect(saved.run.diagnosticsOverlay)
        try saved.activateBuildTarget(id: freshID)
        #expect(!saved.run.diagnosticsOverlay)
        try saved.activateBuildTarget(id: duplicateID)
        #expect(saved.run.diagnosticsOverlay)
    }

    @Test func swiftLaunchOverridesTheProjectEnvironmentForThisRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GameDiagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = ProjectSystem.defaultProject(projectName: "Game", buildSystem: .swiftpm)
        project.run.environment = ["ADAENGINE_DIAGNOSTICS_OVERLAY": "0", "GAME_MODE": "test"]
        try ProjectSystem.saveProject(project, at: root)
        let service = SwiftPMWorkspaceService()
        let toolchain = SwiftToolchain(swiftExecutablePath: "swift", sourceKitLSPExecutablePath: nil)
        let command = service.makeCommand(
            .run(target: "Game", arguments: ["--level", "test"], diagnosticsOverlay: true),
            projectURL: root,
            toolchain: toolchain
        )
        #expect(command.environment["ADAENGINE_DIAGNOSTICS_OVERLAY"] == "1")
        #expect(command.environment["GAME_MODE"] == "test")
        #expect(command.arguments.suffix(3) == ["--", "--level", "test"])
        let build = service.makeCommand(.build(target: "Game"), projectURL: root, toolchain: toolchain)
        #expect(build.environment["ADAENGINE_DIAGNOSTICS_OVERLAY"] == nil)
    }
}
