@_spi(Internal) import AdaApp
@_spi(AdaEngine) import AdaAssets
import AdaECS
import AdaInput
import AdaScene
import AdaScripting
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct ScriptableAsyncBoundaryTests {
    @Test(arguments: [false, true])
    func unrelatedWorldAsyncDefinitionsDoNotBreakALiveHUD(_ sameFile: Bool) async throws {
        let (catalog, object, app) = try fixture(sameFile: sameFile, update: "count += Work.value();")
        defer { ScriptableObjectRegistry.removeScope(app.executionID) }
        for _ in 0..<3 { await app.withExecutionContext { await app.main.runScheduler(.update) } }
        #expect(object.readExportedField("count") == .int(21))
        #expect(catalog.diagnostics.isEmpty, "\(catalog.diagnostics)")
    }

    @Test(arguments: [
        "Tasks.start(Work.perform());",
        "var pending = Work.perform(); pending.resume();",
        "Tasks.promise();", "Tasks.nextFrame();",
        "Time.sleep(0);", "Time.sleepRealTime(0);",
        "Saves.readAsync(\"@user://forbidden.txt\");",
        "Saves.writeAsync(\"@user://forbidden.txt\", \"bad\");",
        "Saves.begin(\"@user://forbidden.txt\");"
    ])
    func scriptableTaskEntryPointsFailOnceBeforeExecutingOrScheduling(_ statement: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScriptableAsync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (catalog, object, app) = try fixture(sameFile: true, update: statement + " count += 1;")
        defer { ScriptableObjectRegistry.removeScope(app.executionID) }
        AssetsManager.initialize(directories: ProjectDirectories(
            source: root,
            assetsDirectory: root.appendingPathComponent("Assets"),
            userDataDirectory: root,
            cacheDirectory: root.appendingPathComponent("Cache")
        ), scopeID: app.executionID)
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        let first = catalog.diagnostics
        #expect(first.contains { $0.contains("world-owned @system") }, "\(first)")
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<20 { await app.withExecutionContext { await app.main.runScheduler(.update) } }
        #expect(catalog.diagnostics == first)
        #expect(object.readExportedField("count") == .int(0))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden.txt").path))
    }

    @Test func asynchronousLifecycleCallbacksRemainRejected() throws {
        let schema = AdaScriptObjectSchema(identifier: "test.async-callback", className: "HUD", version: 1, aliases: [], fields: [:])
        do {
            _ = try AdaScriptObjectCatalog(schemas: [schema], sources: [.init(path: "HUD.ada", source: "class HUD { async func update(context) {} }")])
            Issue.record("An asynchronous scriptable update unexpectedly compiled")
        } catch let error as AdaScriptError {
            #expect(error.description.contains("cannot be async"))
        }
    }

    private func fixture(sameFile: Bool, update: String) throws -> (AdaScriptObjectCatalog, ScriptableObject, AppWorlds) {
        let id = "test.scriptable-async." + UUID().uuidString
        let shared = """
        class Work {
            static var runs = 0;
            static func value() { return 7 + Work.runs; }
            static async func perform() {
                Work.runs += 1;
                await Time.sleepRealTime(0);
                await Saves.writeAsync("@user://forbidden.txt", "bad");
            }
        }
        @system class WorldWorker {
            func update(context) { Tasks.start(Work.perform()); }
        }
        """
        let hud = """
        @scriptable(id: "\(id)") class HUD {
            @export var count = 0;
            func update(context) { \(update) }
        }
        """
        let sources: [AdaScriptSource]
        if sameFile {
            sources = [.init(path: "Mixed.ada", source: shared + "\n" + hud)]
        } else {
            sources = [
                .init(path: "Shared.ada", source: shared),
                .init(path: "HUD.ada", source: "import { Work } from \"./Shared.ada\";\n" + hud)
            ]
        }
        let schema = AdaScriptObjectSchema(identifier: id, className: "HUD", version: 1, aliases: [], fields: ["count": .int(0)])
        let catalog = try AdaScriptObjectCatalog(schemas: [schema], sources: sources)
        let app = AppWorlds(main: World())
        InputPlugin().setup(in: app)
        try ScriptableObjectRegistry.install(catalog.descriptors, in: app.executionID)
        app.withExecutionContext { ScriptableObjectPlugin().setup(in: app) }
        let object = try app.withExecutionContext { try ScriptableObjectRegistry.make(named: id) }
        app.main.spawn { ScriptableComponents(scripts: [object]) }
        return (catalog, object, app)
    }
}
