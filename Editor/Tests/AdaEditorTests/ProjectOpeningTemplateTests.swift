@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("Project opening templates")
struct ProjectOpeningTemplateTests {
    @Test("AdaScript template creates a portable project without SwiftPM")
    @MainActor
    func createAdaScriptProject() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorAdaScriptProject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = EditorProjectStore(
            storageURL: rootURL.appendingPathComponent("projects.json"),
            adaEnginePackageURL: EditorProjectStore.defaultAdaEnginePackageURL()
        )
        let reference = try store.createProject(named: "Script Game", at: rootURL, template: .adaScript, asPackage: true)
        let projectURL = URL(fileURLWithPath: reference.path, isDirectory: true)
        let sourcesURL = projectURL.appendingPathComponent("Sources", isDirectory: true)

        #expect(projectURL.pathExtension == "adaproject")
        #expect(reference.name == "Script-Game")
        #expect(!FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Package.swift").path))
        #expect(!FileManager.default.fileExists(atPath: sourcesURL.appendingPathComponent("AdaRuntimeBootstrap.swift").path))
        #expect(!FileManager.default.fileExists(atPath: sourcesURL.appendingPathComponent("main.swift").path))
        let script = try String(contentsOf: sourcesURL.appendingPathComponent("Main.ada"), encoding: .utf8)
        #expect(script.contains("@previewable"))
        #expect(script.contains("@view(id: \"game.main\")"))
        #expect(script.contains("func body()"))
        #expect(script.contains("@system"))
        #expect(script.contains("func update(context: AdaSystemContext)"))
        let project = try ProjectSystem.loadProject(at: projectURL)
        #expect(project.build.system == .adaScript)
        #expect(project.runtime.entryView == "game.main")
        try ProjectSystem.validateRunCompatibility(of: project, at: projectURL, destination: .iPadOS)
        let report = try EditorAdaScriptProjectBuilder().build(project: project, at: projectURL)
        #expect(report.sourceCount == 1)
        #expect(report.systemCount == 1)
        #expect(report.viewCount == 1)
        #expect(report.entryView == "game.main")
    }

    @Test("AdaScript project accepts portable runtime components without compiling Swift")
    @MainActor
    func adaScriptProjectAcceptsRuntimeComponents() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorAdaScriptDataProject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let reference = try EditorProjectStore(
            storageURL: rootURL.appendingPathComponent("projects.json")
        )
        .createProject(named: "Runtime Data", at: rootURL, template: .adaScript)
        let projectURL = URL(fileURLWithPath: reference.path, isDirectory: true)
        let mainURL = projectURL.appendingPathComponent("Sources/Main.ada")
        let originalSource = try String(contentsOf: mainURL, encoding: .utf8)
        try (originalSource + "\n" + """
        @component(id: "game.health")
        struct Health {
            @export
            var current = 100.0;
        }
        """)
        .write(to: mainURL, atomically: true, encoding: .utf8)
        let project = try ProjectSystem.loadProject(at: projectURL)

        let report = try EditorAdaScriptProjectBuilder().build(project: project, at: projectURL)
        #expect(report.sourceCount == 1)
        #expect(!FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Package.swift").path))
    }

    @Test("Medieval Arena portable project prepares for Play")
    @MainActor
    func medievalArenaPreparesForPlay() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Medieval Arena renderer setup")))
        }
        EditorComponentRegistry.registerBuiltIns()
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Demos/MedievalArena", isDirectory: true)
        let project = try ProjectSystem.loadProject(at: projectURL)
        let artifact = try EditorAdaScriptProjectBuilder().prepare(project: project, at: projectURL)
        let view = try EditorAdaScriptProjectRuntimeView(artifact: artifact)
        let scene = try #require(artifact.sceneModel)
        let world = World(name: "Medieval Arena Play validation")
        let loaded = EditorSceneFileLoader.load(
            model: scene,
            into: world,
            resourceRootURL: artifact.assetsDirectory
        )

        #expect(artifact.report.sourceCount == 4)
        #expect(artifact.report.systemCount == 3)
        #expect(loaded.entityCount == 5)
        #expect(loaded.warnings.isEmpty)
        _ = view
    }

    @Test("launcher exposes project, template, and sample sections with both language templates")
    func projectOpeningSectionsAndTemplates() {
        #expect(ProjectOpeningSection.allCases == [.projects, .templates, .samples])
        #expect(EditorProjectTemplate.allCases == [.adaScript, .adaScriptWithSwift])
        #expect(EditorProjectTemplate.adaScript.displayName == "AdaScript")
        #expect(EditorProjectTemplate.adaScriptWithSwift.displayName == "AdaScript + Swift")
    }
}
