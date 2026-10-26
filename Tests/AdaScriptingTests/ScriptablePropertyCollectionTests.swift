@_spi(Internal) import AdaApp
import AdaECS
import AdaInput
import AdaScene
import AdaScripting
import AdaUI
import Foundation
import Testing

@MainActor
@Suite("Scriptable native property writes under collection", .serialized)
struct ScriptablePropertyCollectionTests {
    @Test func stringUIEditsReachTheLiveInstance() async throws {
        let fixture = try Fixture()
        defer { ScriptableObjectRegistry.removeScope(fixture.app.executionID) }
        let script = try fixture.make(fixture.editableID)
        let ui = UIComponent(source: .init(scriptBindings: ["title": .init(script: fixture.editableID, field: "title")]))
        fixture.world.spawn { ScriptableComponents(scripts: [script]); ui }
        await fixture.update()
        try await fixture.startCollectionPressure()
        Self.checkpoint("UI fixture initialized under collection pressure")
        let binding = try #require(ui.scriptBindingContext)

        for edit in 1...100 {
            let title = "Native UI edit \(edit): строка после collection"
            binding.set("title", to: .string(title))
            if edit == 1 { Self.checkpoint("Applying first queued native String edit") }
            await fixture.update() // The native UI synchronization writes after the script callback.
            await fixture.update() // Observe the value from inside the VM, beyond Swift's payload cache.
            try #require(fixture.catalog.diagnostics.isEmpty, "Edit \(edit): \(fixture.catalog.diagnostics)")
            try #require(binding.diagnostics.isEmpty, "Edit \(edit): \(binding.diagnostics)")
            try #require(script.readExportedField("observed") == .string(title + ":1:2"), "Edit \(edit)")
        }
    }

    @Test func initialStringAndListPayloadReachReady() async throws {
        let fixture = try Fixture()
        defer { ScriptableObjectRegistry.removeScope(fixture.app.executionID) }
        try await fixture.startCollectionPressure()
        Self.checkpoint("Initial-payload fixture initialized under collection pressure")
        let title = "Saved native payload: строка до ready"
        let data = try JSONSerialization.data(withJSONObject: ["scripts": [[
            "type": fixture.editableID, "version": 1,
            "payload": ["title": title, "items": [7, 11], "observed": ""]
        ]]])
        let components = try fixture.app.withExecutionContext {
            try JSONDecoder().decode(ScriptableComponents.self, from: data)
        }
        let script = try #require(components.scripts.first)
        fixture.world.spawn { components }
        Self.checkpoint("Instantiating decoded String/List payload")
        await fixture.update()
        try #require(fixture.catalog.diagnostics.isEmpty, "\(fixture.catalog.diagnostics)")
        #expect(script.readExportedField("observed") == .string(title + ":7:2"))
        #expect(script.readExportedField("items") == .array([.int(7), .int(11)]))
    }

    private static func checkpoint(_ phase: String) {
        // Preserve the failing native-write boundary even if the VM terminates the process.
        FileHandle.standardError.write(Data("Property collection checkpoint: \(phase)\n".utf8))
    }

    @MainActor
    private struct Fixture {
        let editableID = "test.collection-editable"
        let pressureID = "test.collection-pressure"
        let catalog: AdaScriptObjectCatalog
        let world: World
        let app: AppWorlds

        init() throws {
            catalog = try AdaScriptObjectCatalog(schemas: [
                .init(identifier: editableID, className: "Editable", version: 1, aliases: [], fields: [
                    "title": .string("Initial"), "items": .array([.int(1), .int(2)]), "observed": .string("")
                ]),
                .init(identifier: pressureID, className: "Pressure", version: 1, aliases: [], fields: [:])
            ], sources: [.init(path: "PropertyWrites.ada", source: """
            @scriptable(id: "test.collection-editable")
            class Editable {
                @export var title = "Initial";
                var items = [1,2];
                @export var observed = "";
                func ready(context) { observed = title + ":" + items[0] + ":" + items.count; }
                func update(context) { observed = title + ":" + items[0] + ":" + items.count; }
            }
            @scriptable(id: "test.collection-pressure")
            class Pressure {
                var collectionReserve = ["x".repeat(3000000),"y".repeat(3000000)];
                func update(context) {
                    System.gcMinThreshold = 1;
                    System.gcRatio = 0.000001;
                    System.gcThreshold = 1;
                }
            }
            """)])
            world = World(name: "Native property collection")
            app = AppWorlds(main: world)
            try ScriptableObjectRegistry.install(catalog.descriptors, in: app.executionID)
            InputPlugin().setup(in: app)
            app.withExecutionContext { ScriptableObjectPlugin().setup(in: app) }
        }

        func make(_ identifier: String) throws -> ScriptableObject {
            try app.withExecutionContext { try ScriptableObjectRegistry.make(named: identifier) }
        }

        func update() async {
            await app.withExecutionContext { await world.runScheduler(.update) }
        }

        func startCollectionPressure() async throws {
            let pressure = try make(pressureID)
            world.spawn { ScriptableComponents(scripts: [pressure]) }
            await update()
            try #require(catalog.diagnostics.isEmpty, "\(catalog.diagnostics)")
        }
    }
}
