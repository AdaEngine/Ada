@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor build targets", .serialized)
@MainActor
struct EditorBuildTargetsTests {
    @Test("legacy projects retain their settings and acquire targets only when requested")
    func legacyCompatibility() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try ProjectSystem.loadProject(at: root)
        #expect(original.buildTargets.isEmpty)
        #expect(original.activeBuildTargetID == nil)
        try ProjectSystem.saveProject(original, at: root)
        #expect(try ProjectSystem.loadProject(at: root) == original)
        let model = EditorBuildTargetsModel()
        model.begin(original, product: nil)
        model.add()
        #expect(model.draft?.buildTargets.count == 2)
        #expect(try ProjectSystem.loadProject(at: root) == original)
    }

    @Test("switching persisted targets changes the real builder's scene and source membership")
    func persistedTargetsDriveBuilder() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try ProjectSystem.loadProject(at: root)
        project.ensureBuildTargets(defaultName: "Game")
        let mainID = try #require(project.activeBuildTargetID)
        project.build.configuration = "release"
        project.captureActiveBuildTarget()
        var test = AdaProjectBuildTarget(name: "Test Scene", project: project)
        test.startupScene = "Assets/Scenes/Test.ascn"
        test.runtime.entry.scene = test.startupScene
        test.build.configuration = "debug"
        test.build.includedFiles = ["Sources"]
        test.build.excludedFiles = ["Sources/Unused.ada"]
        test.run.arguments = ["--test", "two words"]
        project.buildTargets.append(test)
        try project.activateBuildTarget(id: test.id)
        try ProjectSystem.saveProject(project, at: root)

        var loaded = try ProjectSystem.loadProject(at: root)
        let builder = EditorAdaScriptProjectBuilder()
        let artifact = try builder.prepare(project: loaded, at: root, validatesRuntime: false)
        #expect(artifact.report.startupScene == test.startupScene)
        #expect(artifact.sources.map(\.path) == ["Shared.ada"])
        #expect(loaded.run.arguments == ["--test", "two words"])
        let exportDirectory = loaded.buildTargetExportSubdirectory
        loaded.runtime.window.title = "Test window"
        try ProjectSystem.saveProject(loaded, at: root)
        loaded = try ProjectSystem.loadProject(at: root)
        try loaded.activateBuildTarget(id: mainID)
        try ProjectSystem.saveProject(loaded, at: root)
        loaded = try ProjectSystem.loadProject(at: root)
        #expect(loaded.build.configuration == "release")
        #expect(loaded.build.excludedFiles.isEmpty)
        #expect(loaded.run.arguments.isEmpty)
        #expect(try builder.prepare(project: loaded, at: root, validatesRuntime: false).report.startupScene == "Assets/Scenes/Main.ascn")
        #expect(loaded.buildTargetExportSubdirectory != exportDirectory)
        try loaded.activateBuildTarget(id: test.id)
        #expect(loaded.runtime.window.title == "Test window")
        #expect(loaded.buildTargetExportSubdirectory == exportDirectory)
    }

    @Test("all targets are validated, including inactive targets")
    func validatesTargets() throws {
        var project = ProjectSystem.defaultProject(buildSystem: .adaScript)
        project.ensureBuildTargets(defaultName: "Game")
        var other = AdaProjectBuildTarget(name: "Game", project: project)
        project.buildTargets.append(other)
        #expect(throws: ProjectSystemError.self) { try ProjectSystem.validate(project) }
        project.buildTargets.removeLast()
        other.name = "Test"
        other.runtime.entry.scene = "../Outside.ascn"
        project.buildTargets.append(other)
        #expect(throws: ProjectSystemError.self) { try ProjectSystem.validate(project) }
        project.buildTargets.removeLast()
        #expect(throws: ProjectSystemError.self) { try project.activateBuildTarget(id: "missing") }
        #expect(project.activeBuildTargetID == project.buildTargets.first?.id)
    }

    @Test("Swift commands use the selected configuration before product arguments")
    func swiftCommands() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try ProjectSystem.loadProject(at: root)
        project.build.configuration = "release"
        project.run.environment = ["TARGET_ENV": "test"]
        try ProjectSystem.saveProject(project, at: root)
        let command = SwiftPMWorkspaceService().makeCommand(
            .run(target: "Game", arguments: ["--debug"]), projectURL: root,
            toolchain: SwiftToolchain(swiftExecutablePath: "swift", sourceKitLSPExecutablePath: nil))
        #expect(command.arguments == ["run", "-c", "release", "Game", "--", "--debug"])
        #expect(command.environment["TARGET_ENV"] == "test")
    }

}

extension EditorLocalizationTests {
    @Test("mounted target editor supports duplicate, scene selection, deletion and live language changes")
    func dialogInteraction() async throws {
        EditorBuildTargetsTests().prepareRenderer()
        let root = try EditorBuildTargetsTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorViewModel(project: EditorProjectReference(name: "Game", path: root.path))
        model.presentBuildTargets()
        let oldLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = oldLanguage }
        EditorLocalization.shared.preference = .english
        let container = UIContainerView(rootView: EditorBuildTargetsDialog(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1_024, height: 768)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.BuildTargets.Duplicate"))
        for _ in 0..<10 { await Task.yield(); container.update(1 / 60) }
        container.layoutIfNeeded()
        #expect(model.buildTargets.draft?.buildTargets.count == 2)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.BuildTargets.Scene.Assets/Scenes/Test.ascn"))
        #expect(model.buildTargets.editedTarget?.runtime.entry.scene == "Assets/Scenes/Test.ascn")
        EditorLocalization.shared.preference = .russian
        for _ in 0..<10 { await Task.yield(); container.update(1 / 60) }
        container.layoutIfNeeded()
        let save = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.BuildTargets.Save"))
        let cancel = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.BuildTargets.Cancel"))
        #expect(save.absoluteFrame.maxX <= 1_024)
        #expect(cancel.absoluteFrame.maxX < save.absoluteFrame.minX)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.BuildTargets.Delete"))
        #expect(model.buildTargets.draft?.buildTargets.count == 1)
        #expect(try ProjectSystem.loadProject(at: root).buildTargets.isEmpty)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.BuildTargets.Save"))
        for _ in 0..<200 where model.workspaceTask != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try ProjectSystem.loadProject(at: root).buildTargets.count == 1)
        #expect(!model.buildTargets.isPresented)
        let reopened = EditorViewModel(project: EditorProjectReference(name: "Game", path: root.path))
        #expect(reopened.buildTargets.activeName == model.buildTargets.activeName)
    }
}

extension EditorBuildTargetsTests {
    @Test("toolbar picker activates the chosen target and refuses changes during a run")
    func pickerInteraction() async throws {
        prepareRenderer()
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try ProjectSystem.loadProject(at: root)
        project.ensureBuildTargets(defaultName: "Game")
        let mainID = try #require(project.activeBuildTargetID)
        var target = AdaProjectBuildTarget(name: "Test", project: project)
        target.startupScene = "Assets/Scenes/Test.ascn"
        target.runtime.entry.scene = target.startupScene
        project.buildTargets.append(target)
        try ProjectSystem.saveProject(project, at: root)
        let model = EditorViewModel(project: EditorProjectReference(name: "Game", path: root.path))
        let menu = UIContainerView(rootView: EditorBuildTargetMenu(viewModel: model).theme(.adaEditor))
        menu.frame = Rect(x: 0, y: 0, width: 258, height: 260)
        menu.bounds.size = menu.frame.size
        menu.layoutIfNeeded()
        _ = try menu.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.BuildTarget.Select.\(target.id)"))
        for _ in 0..<200 where model.workspaceTask != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try ProjectSystem.loadProject(at: root).runtime.entry.scene == target.startupScene)
        #expect(model.buildTargets.activeID == target.id)
        model.workspaceStatus = .running("Run")
        model.selectBuildTarget(mainID)
        #expect(try ProjectSystem.loadProject(at: root).activeBuildTargetID == target.id)
    }

    @Test("target picker fits between search and platform", arguments: [Float(1_024), 1_280, 1_728])
    func toolbarLayout(width: Float) throws {
        prepareRenderer()
        let size = Size(width: width, height: AdaEngineStyleLayoutSpec.topToolbarHeight)
        let model = EditorBuildTargetsModel()
        let container = UIContainerView(rootView: EditorTopToolbar(
            project: nil, isProjectSwitcherPresented: false, isRunDestinationMenuPresented: false,
            viewModel: EditorToolbarViewModel(), runDestination: .windows,
            isRunEnabled: true, isStopEnabled: false, onToggleRunDestinationMenu: {}, onToggleProjectSwitcher: {},
            onRun: {}, onStop: {}, onDebug: {}, buildTargets: model
        ).environment(\.metrics, AdaEngineStyleLayoutMetrics(size: size)).theme(.adaEditor))
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()
        let picker = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.BuildTarget.Button"))
        let destination = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.RunDestination.Button"))
        let search = try container.uiNode(matching: .accessibilityIdentifier(EditorTopToolbar.searchAccessibilityIdentifier))
        #expect(picker.absoluteFrame.maxX < destination.absoluteFrame.minX)
        #expect(search.absoluteFrame.maxX < picker.absoluteFrame.minX)
        #expect(picker.absoluteFrame.minX >= 0)
        #expect(destination.absoluteFrame.maxX <= width)
    }

    fileprivate func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildTargets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/Scenes"), withIntermediateDirectories: true)
        try "class Shared {}".write(to: root.appendingPathComponent("Sources/Shared.ada"), atomically: true, encoding: .utf8)
        try "class Unused {}".write(to: root.appendingPathComponent("Sources/Unused.ada"), atomically: true, encoding: .utf8)
        for name in ["Main", "Test"] {
            try SceneDocumentFormat.defaultSceneYAML(projectName: name).write(
                to: root.appendingPathComponent("Assets/Scenes/\(name).ascn"), atomically: true, encoding: .utf8)
        }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Game", buildSystem: .adaScript), at: root)
        return root
    }

    fileprivate func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "BuildTargets")))
        }
    }
}
