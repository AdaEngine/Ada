@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor AdaScript hot reload", .serialized)
struct EditorAdaScriptHotReloadTests {
    @Test("A newly added startup system runs once during reload")
    @MainActor
    func runsNewStartupSystem() async throws {
        let original = AdaScriptSource(path: "Main.ada", source: """
        @system(id: "live.idle")
        class IdleSystem { func update(context) {} }
        """)
        let app = AppWorlds(main: World(name: "AdaScript startup reload"))
        let plugin = try AdaScriptPlugin(sources: [original], name: "StartupReload")
        plugin.setup(in: app)
        await app.main.runScheduler(.update)
        #expect(app.main.getEntities().isEmpty)

        let updated = AdaScriptSource(path: "Main.ada", source: original.source + """

        @system(id: "live.startup", scheduler: "startup")
        class StartupSystem {
            func update(context) { context.world.commands.spawn([]); }
        }
        """)
        try await plugin.reload(sources: [updated], in: app)
        #expect(app.main.getEntities().count == 1)
        await app.main.runScheduler(.update)
        #expect(app.main.getEntities().count == 1)
    }

    @Test("The editor applies an unsaved change to a running game world")
    @MainActor
    func appliesUnsavedChangeToGame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptLiveGame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let sourceURL = sources.appendingPathComponent("Main.ada")
        func source(spawns: Int) -> String {
            let statements = Array(repeating: "context.world.commands.spawn([]);", count: spawns).joined(separator: "\n")
            return """
            @system(id: "editor.live")
            class LiveSystem {
                func update(context) {
                    \(statements)
                }
            }
            """
        }
        try source(spawns: 1).write(to: sourceURL, atomically: true, encoding: .utf8)
        var project = ProjectSystem.defaultProject(projectName: "Live", buildSystem: .adaScript)
        project.runtime.entry.view = nil
        project.runtime.entry.scene = nil
        let builder = EditorAdaScriptProjectBuilder()
        let initial = try builder.prepare(project: project, at: root)
        let app = AppWorlds(main: World(name: "Editor live game"))
        let plugin = try #require(try initial.scenePlayRuntime.makeScriptPlugin())
        plugin.setup(in: app)
        let controls = EditorGameWindowControls(projectSize: Size(width: 640, height: 480))
        controls.attach(app: app, scriptPlugin: plugin, sources: initial.sources, scriptableSchemas: [])

        await app.main.runScheduler(.update)
        #expect(app.main.getEntities().count == 1)

        let candidate = try builder.prepare(
            project: project,
            at: root,
            sourceOverrides: ["Sources/Main.ada": source(spawns: 2)],
            validatesRuntime: false
        )
        #expect(try await controls.reloadAdaScript(candidate))
        await app.main.runScheduler(.update)

        #expect(app.main.getEntities().count == 3)
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == source(spawns: 1))

        do {
            try await plugin.reload(
                sources: [AdaScriptSource(path: "Main.ada", source: "@system class Broken {")],
                in: app
            )
            Issue.record("Invalid code unexpectedly replaced the running module")
        } catch {
            await app.main.runScheduler(.update)
            #expect(app.main.getEntities().count == 5)
        }
    }

    @Test("A live scriptable object keeps exported state after its code changes")
    @MainActor
    func scriptableObjectKeepsState() async throws {
        let schema = AdaScriptObjectSchema(
            identifier: "editor.hot-scriptable-counter",
            className: "HotCounter",
            version: 1,
            aliases: [],
            fields: ["count": .int(0)]
        )
        func source(increment: Int) -> AdaScriptSource {
            AdaScriptSource(path: "HotCounter.ada", source: """
            @scriptable(id: "editor.hot-scriptable-counter", version: 1)
            class HotCounter {
                @export var count = 0;
                func update(context) { count += \(increment); }
            }
            """)
        }
        let original = source(increment: 1)
        try AdaScriptObjectRegistration.register(schemas: [schema], sources: [original], moduleName: "EditorHotCounter")
        let script = try ScriptableObjectRegistry.make(named: schema.identifier)
        let app = AppWorlds(main: World(name: "Editor scriptable hot reload"))
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        app.main.spawn { ScriptableComponents(scripts: [script]) }
        let plugin = try AdaScriptPlugin(sources: [original], name: "EditorHotCounter")
        plugin.setup(in: app)

        await app.main.runScheduler(.update)
        #expect(try exportedCount(script) == 1)

        let updated = source(increment: 5)
        let candidate = try AdaScriptObjectRegistration.prepareReload(
            schemas: [schema], sources: [updated], moduleName: "EditorHotCounter"
        )
        try await plugin.reload(sources: [updated], in: app, scriptableObjects: candidate)
        await app.main.runScheduler(.update)

        #expect(try exportedCount(script) == 6)

        do {
            _ = try AdaScriptObjectRegistration.prepareReload(
                schemas: [schema],
                sources: [AdaScriptSource(path: "HotCounter.ada", source: "@scriptable class Broken {")],
                moduleName: "EditorHotCounter"
            )
            Issue.record("Invalid scriptable code unexpectedly compiled")
        } catch {
            await app.main.runScheduler(.update)
            #expect(try exportedCount(script) == 11)
        }
    }

    private func exportedCount(_ script: ScriptableObject) throws -> Int? {
        let data = try JSONEncoder().encode(ScriptableComponents(scripts: [script]))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scripts = try #require(object["scripts"] as? [[String: Any]])
        let payload = try #require(scripts.first?["payload"] as? [String: Any])
        return payload["count"] as? Int
    }

    @Test("Builds a running candidate from an unsaved editor buffer")
    @MainActor
    func usesUnsavedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptHotReload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Main.ada")
        try "@system class Invalid {".write(to: file, atomically: true, encoding: .utf8)
        var project = ProjectSystem.defaultProject(projectName: "Live", buildSystem: .adaScript)
        project.runtime.entry.view = nil
        project.runtime.entry.scene = nil
        let editedSource = """
        @system(id: "live.system")
        class LiveSystem {
            func update(context) {}
        }
        """

        let artifact = try EditorAdaScriptProjectBuilder().prepare(
            project: project,
            at: root,
            sourceOverrides: ["Sources/Main.ada": editedSource]
        )

        #expect(artifact.sources.first?.source == editedSource)
        #expect(artifact.report.systemCount == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "@system class Invalid {")
    }
}
