@_spi(Internal) @testable import AdaApp
@_spi(Scripting) import AdaECS
@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing
@testable import AdaEditor

@MainActor
@Suite("Editor Scene Play navigation", .serialized)
struct EditorScenePlayNavigationTests {
    @Test("Viewport Play replaces and reloads editor scenes through the AdaScript world API")
    func viewportNavigation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let world = fixture.app.main
        let navigator = try #require(world.getResource(SceneNavigator.self))
        await fixture.app.withExecutionContext { await world.runScheduler(.update, deltaTime: 0.1) }
        try set("target", .string("@res://Scenes/Second.ascn"), actor: "First actor", world: world)
        await fixture.app.withExecutionContext { await world.runScheduler(.update, deltaTime: 0.1) }
        for _ in 0..<100 where world.getEntityByName("Second actor") == nil {
            await fixture.app.withExecutionContext { await world.runScheduler(.postUpdate, deltaTime: 0.1) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(world.getEntityByName("First actor") == nil)
        _ = try #require(world.getEntityByName("Second actor"))
        #expect(navigator.lastError == nil)
        await fixture.app.withExecutionContext { await world.runScheduler(.update, deltaTime: 0.1) }
        #expect(try value("ticks", actor: "Second actor", world: world) == .int(1))
        #expect(sessionVisits(world) == .int(3))

        try set("reload", .bool(true), actor: "Second actor", world: world)
        await fixture.app.withExecutionContext { await world.runScheduler(.update, deltaTime: 0.1) }
        for _ in 0..<100 where try value("ticks", actor: "Second actor", world: world) != .int(0) {
            await fixture.app.withExecutionContext { await world.runScheduler(.postUpdate, deltaTime: 0.1) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try value("ticks", actor: "Second actor", world: world) == .int(0))
        await fixture.app.withExecutionContext { await world.runScheduler(.update, deltaTime: 0.1) }
        #expect(try value("ticks", actor: "Second actor", world: world) == .int(1))
        #expect(sessionVisits(world) == .int(5))
    }

    @Test("Viewport navigation rejects paths outside the resource root and retains the active scene")
    func invalidNavigationRetainsScene() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let world = fixture.app.main
        let navigator = try #require(world.getResource(SceneNavigator.self))
        for path in ["@res://../Outside.ascn", "/tmp/Outside.ascn"] {
            try set("target", .string(path), actor: "First actor", world: world)
            await fixture.app.withExecutionContext { await world.runScheduler(.update, deltaTime: 0.1) }
            for _ in 0..<100 where navigator.lastError == nil {
                await fixture.app.withExecutionContext { await world.runScheduler(.postUpdate, deltaTime: 0.1) }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(navigator.lastError?.contains("Invalid project scene path") == true)
            _ = try #require(world.getEntityByName("First actor"))
            #expect(world.getEntityByName("Second actor") == nil)
        }
    }

    private func makeFixture() async throws -> (root: URL, app: AppWorlds) {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Scene Play navigation setup")))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScenePlayNavigation-\(UUID().uuidString)")
        let assets = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("Scenes"), withIntermediateDirectories: true)
        let source = AdaScriptSource(path: "Navigation.ada", source: """
            @component(id: "test.navigation")
            struct NavigationCommand { @export var target = ""; @export var reload = false; @export var ticks = 0; }
            @resource(id: "test.navigation.session")
            struct Session { @export var visits = 0; }
            @system(id: "test.navigation.driver")
            class NavigationDriver {
                @res var session: Session;
                @query(NavigationCommand) var commands;
                var ticks = 0;
                func update(context) {
                    ticks += 1; session.visits += 1;
                    for (var row in commands) {
                        row.navigationCommand.ticks = ticks;
                        if (row.navigationCommand.target != "") {
                            var target = row.navigationCommand.target; row.navigationCommand.target = "";
                            context.world.changeScene(target);
                        }
                        if (row.navigationCommand.reload) { row.navigationCommand.reload = false; context.world.reloadScene(); }
                    }
                }
            }
            """)
        var project = AdaProject(schemaVersion: 3)
        project.runtime.entry.view = nil
        project.runtime.moduleName = "ScenePlayNavigation"
        let runtime = try EditorScriptableObjectCatalogLoader.makeResult(project: project, sources: [source]).playRuntime
        let first = scene("First")
        let content = try first.encodedYAML()
        let initialURL = assets.appendingPathComponent("Scenes/First.ascn")
        try content.write(to: initialURL, atomically: true, encoding: .utf8)
        try scene("Second").encodedYAML().write(to: assets.appendingPathComponent("Scenes/Second.ascn"), atomically: true, encoding: .utf8)
        let document = EditorSceneDocument(id: "navigation", title: "First.ascn", relativePath: "Assets/Scenes/First.ascn",
            absolutePath: initialURL.path, content: content, lastSavedContent: content, sceneModel: first,
            errorMessage: nil, isDirty: false, statusMessage: nil, loadSummary: .empty)
        let viewport = EditorSceneViewportView(document: document, resourceRootURL: assets,
            inspectorViewModel: EditorInspectorSidebarViewModel(), playModeState: .playing(sceneDocumentID: document.id, title: document.title),
            playRuntime: runtime, onEntitySelected: nil, onPlay: nil, onStop: nil, onDocumentChanged: { _ in })
        var app = AppWorlds(main: World(name: "Viewport Play navigation"))
        app.addPlugin(MainSchedulerPlugin())
        viewport.configurePlayWorld(&app)
        try await app.build()
        _ = try #require(app.main.getEntityByName("First actor"))
        return (root, app)
    }

    private func scene(_ name: String) -> EditorSceneModel {
        EditorSceneModel(scene: .init(id: name, name: name), entities: [
            EditorSceneEntity(id: "actor", name: name + " actor", enabled: true, parent: nil, components: ["test.navigation": [:]])
        ])
    }

    private func value(_ key: String, actor: String, world: World) throws -> ReflectedFieldValue? {
        let entity = try #require(world.getEntityByName(actor))
        let descriptor = try #require(world.runtimeComponentDescriptor(named: "test.navigation"))
        let payload = try #require(world.getRuntimeComponent(descriptor.componentID, from: entity.id))
        return descriptor.fields.first { $0.key == key }?.read(payload)
    }

    private func set(_ key: String, _ value: ReflectedFieldValue, actor: String, world: World) throws {
        let entity = try #require(world.getEntityByName(actor))
        let descriptor = try #require(world.runtimeComponentDescriptor(named: "test.navigation"))
        let payload = try #require(world.getRuntimeComponent(descriptor.componentID, from: entity.id))
        let field = try #require(descriptor.fields.first { $0.key == key })
        let updated = try #require(field.write(payload, value) as? RuntimeComponentPayload)
        world.insertRuntimeComponent(updated, for: entity.id)
    }

    private func sessionVisits(_ world: World) -> ReflectedFieldValue? {
        world.getResource(RuntimeResourceStore.self)?.payloads["test.navigation.session"]?.values.first
    }
}
