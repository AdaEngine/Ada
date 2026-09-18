import AdaPlayerConnect
import Foundation
import Testing

@testable import AdaEditor

@Suite("AdaPlayer project packaging")
struct EditorPlayerProjectTests {
    @Test func portableProjectBuildsThroughTheRealRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try "@view class HUD { func body() { Text(\"Device preview\"); } }"
            .write(
                to: project.appendingPathComponent("Sources/HUD.ada"),
                atomically: true,
                encoding: .utf8
            )
        try Data([1, 2, 3]).write(to: project.appendingPathComponent("Assets/example.bin"))
        var settings = ProjectSystem.defaultProject(projectName: "Game", buildSystem: .adaScript)
        settings.runtime.entry = AdaProjectRuntimeEntry(view: "HUD")
        settings.ai.agent.target.environment = ["PRIVATE_TEST_VALUE": "local-only"]
        settings.run.environment = ["PRIVATE_RUN_VALUE": "local-only"]
        try ProjectSystem.saveProject(settings, at: project)
        let snapshot = try await EditorPlayerProjectPackager.prepare(at: project)
        #expect(snapshot.files.contains { $0.path == "Assets/example.bin" })
        let installed = try snapshot.install(in: root.appendingPathComponent("Device"))
        let received = try ProjectSystem.loadProject(at: installed)
        #expect(received.ai.agent.target.environment.isEmpty)
        #expect(received.run.environment.isEmpty)
        let artifact = try EditorAdaScriptProjectBuilder().prepare(project: received, at: installed)
        #expect(artifact.entry.view == "HUD")
        #expect(artifact.sources.count == 1)
        #expect(try Data(contentsOf: artifact.assetsDirectory.appendingPathComponent("example.bin")) == Data([1, 2, 3]))
    }

    @Test func rejectsNativeSwiftProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Native", buildSystem: .swiftpm), at: root)
        await #expect(throws: ProjectSystemError.self) {
            try await EditorPlayerProjectPackager.prepare(at: root)
        }
    }
}
