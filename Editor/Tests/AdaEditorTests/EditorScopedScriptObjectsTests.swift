@_spi(Internal) import AdaApp
import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorScopedScriptObjectsTests {
    @Test func equalIdentifiersInIndependentGamesUseCurrentSourceAndSeparateState() async throws {
        let id = "test.scoped-hud." + UUID().uuidString
        func game(increment: Int) throws -> (AppWorlds, ScriptableObject, AdaScriptObjectCatalog) {
            let sources = [AdaScriptSource(path: "HUD.ada", source: """
            @scriptable(id: "\(id)")
            class HUD {
                @export var count = 0;
                func update(context) { count += \(increment); }
            }
            """)]
            let runtime = try EditorScriptableObjectCatalogLoader.makeResult(project: AdaProject(schemaVersion: 3), sources: sources).playRuntime
            let catalog = try runtime.makeScriptableCatalog()
            let app = AppWorlds(main: World())
            InputPlugin().setup(in: app)
            EditorProjectScriptObjectsPlugin(catalog: catalog).setup(in: app)
            let object = try app.withExecutionContext { try ScriptableObjectRegistry.make(named: id) }
            app.main.spawn { ScriptableComponents(scripts: [object]) }
            return (app, object, catalog)
        }
        let (first, firstHUD, firstCatalog) = try game(increment: 1)
        let (second, secondHUD, secondCatalog) = try game(increment: 10)
        for _ in 0..<20 {
            await first.withExecutionContext { await first.main.runScheduler(.update) }
            await second.withExecutionContext { await second.main.runScheduler(.update) }
        }
        #expect(firstHUD.readExportedField("count") == .int(20))
        #expect(secondHUD.readExportedField("count") == .int(200))
        #expect(firstCatalog.diagnostics.isEmpty && secondCatalog.diagnostics.isEmpty)
        #expect(ScriptableObjectRegistry.descriptor(named: id) == nil)
    }

    @Test func refusedUIWriteRetainsOriginalVMFailure() async throws {
        let id = "test.failed-ui-write." + UUID().uuidString
        let sources = [AdaScriptSource(path: "HUD.ada", source: """
        @scriptable(id: "\(id)") class HUD {
            @export var selected = true;
            func update(context) { var zero = 0; var invalid = 1 / zero; }
        }
        """)]
        let runtime = try EditorScriptableObjectCatalogLoader.makeResult(project: AdaProject(schemaVersion: 3), sources: sources).playRuntime
        let catalog = try runtime.makeScriptableCatalog()
        let app = AppWorlds(main: World())
        InputPlugin(actions: []).setup(in: app)
        EditorProjectScriptObjectsPlugin(catalog: catalog).setup(in: app)
        defer { ScriptableObjectRegistry.removeScope(app.executionID) }
        let script = try app.withExecutionContext { try ScriptableObjectRegistry.make(named: id) }
        let ui = UIComponent(source: .init(scriptBindings: ["selected": .init(script: id, field: "selected")]))
        app.main.spawn { ui; ScriptableComponents(scripts: [script]) }
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        let originalFailure = try #require(catalog.diagnostics.first)
        let context = try #require(ui.scriptBindingContext)
        context.set("selected", to: .bool(false))
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        #expect(script.readExportedField("selected") == .bool(true))
        #expect(catalog.diagnostics.contains { $0.contains("[quarantined]") && $0.contains(String(originalFailure.prefix(500))) })
        let failureCount = catalog.diagnostics.count
        context.set("selected", to: .bool(false))
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        #expect(catalog.diagnostics.count == failureCount)
    }

    @Test func scopedReloadReplacesLiveAndFutureFactories() async throws {
        let id = "test.scoped-reload." + UUID().uuidString
        func source(_ increment: Int) -> [AdaScriptSource] {
            [.init(path: "HUD.ada", source: """
            @scriptable(id: "\(id)")
            class HUD { @export var count = 0; func update(context) { count += \(increment); } }
            """)]
        }
        let original = source(1)
        let runtime = try EditorScriptableObjectCatalogLoader.makeResult(project: AdaProject(schemaVersion: 3), sources: original).playRuntime
        let catalog = try runtime.makeScriptableCatalog()
        let app = AppWorlds(main: World())
        InputPlugin().setup(in: app)
        EditorProjectScriptObjectsPlugin(catalog: catalog).setup(in: app)
        let plugin = try AdaScriptPlugin(sources: original, name: "Scoped HUD")
        plugin.setup(in: app)
        let live = try app.withExecutionContext { try ScriptableObjectRegistry.make(named: id) }
        app.main.spawn { ScriptableComponents(scripts: [live]) }
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        let replacement = source(5)
        let candidate = try AdaScriptObjectRegistration.prepareReload(schemas: runtime.schemas, sources: replacement, moduleName: "Scoped HUD", replacing: catalog)
        try await plugin.reload(sources: replacement, in: app, scriptableObjects: candidate)
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        #expect(live.readExportedField("count") == .int(6))
        let future = try app.withExecutionContext { try ScriptableObjectRegistry.make(named: id) }
        app.main.spawn { ScriptableComponents(scripts: [future]) }
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        #expect(future.readExportedField("count") == .int(5))
        #expect(ScriptableObjectRegistry.descriptor(named: id) == nil)
    }

    @Test func releasingAGameRemovesOnlyItsScriptableScope() throws {
        let id = "test.scoped-lifetime." + UUID().uuidString
        let sources = [
            AdaScriptSource(path: "HUD.ada", source: """
            @scriptable(id: "\(id)") class HUD { @export var count = 0; }
            """)
        ]
        let runtime = try EditorScriptableObjectCatalogLoader.makeResult(project: AdaProject(schemaVersion: 3), sources: sources).playRuntime
        func game() throws -> AppWorlds {
            let app = AppWorlds(main: World())
            EditorProjectScriptObjectsPlugin(catalog: try runtime.makeScriptableCatalog()).setup(in: app)
            return app
        }
        var stopped: AppWorlds? = try game()
        let stoppedScope = try #require(stopped?.executionID)
        weak var stoppedWorld = stopped?.main
        let running = try game()
        #expect(AppWorldsExecutionContext.$currentID.withValue(stoppedScope) { ScriptableObjectRegistry.descriptor(named: id) != nil })

        stopped = nil

        #expect(stoppedWorld == nil)
        #expect(AppWorldsExecutionContext.$currentID.withValue(stoppedScope) { ScriptableObjectRegistry.descriptor(named: id) == nil })
        #expect(running.withExecutionContext { ScriptableObjectRegistry.descriptor(named: id) != nil })
    }

    @Test func editorReloadReportsOnlyTheActiveScriptableGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScopedReload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let id = "test.scoped-diagnostics." + UUID().uuidString
        func source(failing: Bool) -> String {
            let update = failing ? "var zero = 0; count = 1 / zero;" : "count += 1;"
            return """
            @scriptable(id: "\(id)")
            class HUD { @export var count = 0; func update(context) { \(update) } }
            """
        }
        try source(failing: false).write(to: sourceRoot.appendingPathComponent("HUD.ada"), atomically: true, encoding: .utf8)
        var project = ProjectSystem.defaultProject(projectName: "ScopedReload", buildSystem: .adaScript)
        project.runtime.entry.view = nil
        project.runtime.entry.scene = nil
        let builder = EditorAdaScriptProjectBuilder()
        let original = try builder.prepare(project: project, at: root)
        let catalog = try original.scenePlayRuntime.makeScriptableCatalog()
        let plugin = try #require(try original.scenePlayRuntime.makeScriptPlugin())
        let app = AppWorlds(main: World())
        InputPlugin().setup(in: app)
        EditorProjectScriptObjectsPlugin(catalog: catalog).setup(in: app)
        plugin.setup(in: app)
        let live = try app.withExecutionContext { try ScriptableObjectRegistry.make(named: id) }
        app.main.spawn { ScriptableComponents(scripts: [live]) }
        let controls = EditorGameWindowControls(projectSize: Size(width: 640, height: 480))
        controls.attach(
            app: app,
            scriptPlugin: plugin,
            sources: original.sources,
            scriptableSchemas: original.scenePlayRuntime.schemas,
            scriptableCatalog: catalog
        )
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        #expect(catalog.diagnostics.isEmpty)

        let broken = try builder.prepare(
            project: project,
            at: root,
            sourceOverrides: ["Sources/HUD.ada": source(failing: true)],
            validatesRuntime: false
        )
        #expect(try await controls.reloadAdaScript(broken))
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        #expect(!catalog.diagnostics.isEmpty)
        #expect(live.readExportedField("count") == .int(1))

        #expect(try await controls.reloadAdaScript(original))
        #expect(catalog.diagnostics.isEmpty)
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        #expect(catalog.diagnostics.isEmpty)
        #expect(live.readExportedField("count") == .int(2))
    }
}
