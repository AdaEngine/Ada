@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@Suite("Responsive project loading", .serialized)
@MainActor
struct EditorProjectLoadingTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ProjectLoadingTests")))
        }
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test("Prepare real files off the UI actor and reuse the snapshot when opening the workspace")
    func preparedWorkspace() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = EditorProjectReference(name: "Startup", path: root.path)
        let recorder = StartupProgressRecorder()
        let data = try await EditorProjectStartupLoader.prepare(project: project) { phase in
            await recorder.append(phase)
        }
        #expect(recorder.phases == [.settings, .files, .scripts, .document])
        #expect(data.items.contains { $0.relativePath == "Assets/Scenes/Start.ascn" })
        #expect(!data.items.contains { $0.relativePath.hasPrefix(".builds") || $0.relativePath.hasPrefix(".ada") })
        #expect(data.scriptSupport?.playRuntime.sources.count == 1)
        #expect(data.restoredDocument?.relativePath == "Assets/Scenes/Start.ascn")

        // Opening the prepared workspace must not repeat file traversal, script reads
        // or the restored document read. Its immutable snapshot remains authoritative.
        try FileManager.default.moveItem(at: root.appendingPathComponent("Sources/Game.ada"),
                                         to: root.appendingPathComponent("Sources/Moved.ada"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("Assets/Scenes/Start.ascn"),
                                         to: root.appendingPathComponent("Assets/Scenes/Moved.ascn"))
        let model = EditorViewModel(project: project, startupData: data)
        await model.agent.loadSessions()
        #expect(model.projectSidebar.items == data.items)
        #expect(model.scenePlayRuntime?.sources.first?.path == "Game.ada")
        #expect(model.workbench.activeDocument?.relativePath == "Assets/Scenes/Start.ascn")
        #expect(model.workbench.activeSceneDocument?.errorMessage == nil)
    }

    @Test("A closed project cannot install its cancelled workspace")
    func cancelledLoad() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorProjectLoadingModel()
        let task = Task { await model.load(project: .init(name: "Cancelled", path: root.path)) }
        task.cancel()
        await task.value
        #expect(model.viewModel == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("The file snapshot preserves folder-first natural ordering and resource roots")
    func fileIndexOrdering() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Pack10", "Pack2"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/\(name)"), withIntermediateDirectories: true)
        }
        for name in ["File10.txt", "File2.txt"] {
            try name.write(to: root.appendingPathComponent("Assets/\(name)"), atomically: true, encoding: .utf8)
        }
        let data = try await EditorProjectStartupLoader.prepare(project: .init(name: "Startup", path: root.path))
        let children = data.items.filter { $0.level == 1 && $0.relativePath.hasPrefix("Assets/") }
        #expect(children.map(\.title) == ["Pack2", "Pack10", "Scenes", "File2.txt", "File10.txt"])
        #expect(children.allSatisfy { $0.assetRoot == "Assets" })
    }

    @Test("Invalid metadata shows an error and a later retry can open the repaired project")
    func retryAfterFailure() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try ProjectSystem.loadProject(at: root)
        try "broken json".write(to: root.appendingPathComponent(".ada/project.json"), atomically: true, encoding: .utf8)
        let project = EditorProjectReference(name: "Startup", path: root.path)
        let model = EditorProjectLoadingModel()
        await model.load(project: project)
        #expect(model.errorMessage != nil)
        #expect(model.viewModel == nil)
        try ProjectSystem.saveProject(metadata, at: root)
        await model.load(project: project)
        await model.viewModel?.agent.loadSessions()
        #expect(model.errorMessage == nil)
        #expect(model.viewModel?.project?.path == root.path)
    }

    @Test("Mounted progress follows the current stage and fits both interface languages")
    func mountedProgress() async throws {
        let previous = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previous }
        let model = EditorProjectLoadingModel()
        model.phase = .files
        let container = UIContainerView(rootView: EditorProjectLoadingView(
            project: .init(name: "Большой проект", path: "/project"), model: model
        ))
        container.frame = Rect(x: 0, y: 0, width: 800, height: 600)
        container.bounds.size = container.frame.size
        for language in [EditorLanguage.english, .russian] {
            EditorLocalization.shared.preference = language
            await settle(container)
            let phase = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectLoading.Phase")).absoluteFrame
            let bar = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.LoadingProgress.Bar")).absoluteFrame
            #expect(phase.width > 0 && phase.width < 800)
            #expect(bar.width == 340 && bar.minX >= 0 && bar.maxX <= 800)
        }
        let before = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.LoadingProgress.Fill")).absoluteFrame.width
        model.phase = .workspace
        await settle(container)
        let after = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.LoadingProgress.Fill")).absoluteFrame.width
        #expect(after > before)
        #expect(abs(after - 272) < 1)
    }

    private func settle<V: View>(_ container: UIContainerView<V>) async {
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaStartup-\(UUID().uuidString)", isDirectory: true)
        for directory in ["Sources", "Assets/Scenes", ".ada/workspace", ".builds/ignored"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        var metadata = ProjectSystem.defaultProject(projectName: "Startup", buildSystem: .adaScript)
        metadata.runtime.entry.scene = "Assets/Scenes/Start.ascn"
        metadata.editor.startupScene = "Assets/Scenes/Start.ascn"
        try ProjectSystem.saveProject(metadata, at: root)
        try "func main() {}".write(to: root.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
        try EditorSceneModel.default(projectName: "Startup").encodedYAML()
            .write(to: root.appendingPathComponent("Assets/Scenes/Start.ascn"), atomically: true, encoding: .utf8)
        try #"{"relativePath":"Assets/Scenes/Start.ascn"}"#
            .write(to: root.appendingPathComponent(".ada/workspace/editor-session.json"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent(".builds/ignored/Generated.ada"), atomically: true, encoding: .utf8)
        return root
    }
}

@MainActor
private final class StartupProgressRecorder {
    var phases: [EditorProjectLoadingPhase] = []
    func append(_ phase: EditorProjectLoadingPhase) { phases.append(phase) }
}
