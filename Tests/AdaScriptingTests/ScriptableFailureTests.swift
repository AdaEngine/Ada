@testable import AdaApp
import AdaECS
import AdaInput
import AdaScene
import AdaScripting
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct ScriptableFailureTests {
    @Test func failedConstructorRunsOnceAndRetainsDefaultPayload() async throws {
        let id = "test.failed-init." + UUID().uuidString
        let schema = AdaScriptObjectSchema(identifier: id, className: "Broken", version: 1, aliases: [], fields: ["count": .int(7)])
        let sources = [AdaScriptSource(path: "Broken.ada", source: """
        @scriptable(id: "\(id)")
        class Broken {
            @export var count = 7;
            func init() { var divisor = 0; count = 1 / divisor; }
        }
        """)]
        let catalog = try AdaScriptObjectCatalog(schemas: [schema], sources: sources)
        for descriptor in catalog.descriptors { try ScriptableObjectRegistry.register(descriptor) }
        let object = try ScriptableObjectRegistry.make(named: id)
        let world = World()
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        world.spawn { ScriptableComponents(scripts: [object]) }
        await world.runScheduler(.update)
        let diagnosticCount = catalog.diagnostics.count
        #expect(diagnosticCount > 0)
        for _ in 0..<100 { await world.runScheduler(.update) }
        #expect(catalog.diagnostics.count == diagnosticCount)
        #expect(catalog.diagnostics.allSatisfy { $0.count < 1_000 })
        #expect(object.readExportedField("count") == .int(7))
    }

    @Test func failedCallbackQuarantinesItsModuleWithoutRepeating() async throws {
        let id = "test.callback." + UUID().uuidString
        let schema = AdaScriptObjectSchema(identifier: id, className: "Bad", version: 1, aliases: [], fields: ["count": .int(0)])
        let sources = [AdaScriptSource(path: "Callback.ada", source: """
        class Bad { var count = 0; func update(context) { var zero = 0; count = 1 / zero; } }
        """)]
        let catalog = try AdaScriptObjectCatalog(schemas: [schema], sources: sources)
        for descriptor in catalog.descriptors { try ScriptableObjectRegistry.register(descriptor) }
        let object = try ScriptableObjectRegistry.make(named: id)
        let world = World()
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        world.spawn { ScriptableComponents(scripts: [object]) }
        await world.runScheduler(.update)
        let count = catalog.diagnostics.count
        for _ in 0..<19 { await world.runScheduler(.update) }
        #expect(count > 0 && catalog.diagnostics.count == count)
        #expect(object.readExportedField("count") == .int(0))
    }
}
