@testable import AdaApp
@_spi(Scripting) import AdaECS
import AdaInput
import AdaScene
import AdaScriptCompilerCore
import AdaScripting
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct AdaScriptIdentifiersTests {
    private func check(_ value: String) {
        #expect(value.utf8.count == 36)
        #expect(UUID(uuidString: value)?.uuidString.lowercased() == value)
        #expect(value != "00000000-0000-0000-0000-000000000000")
    }

    @Test func systemsProduceFreshCanonicalUUIDsAcrossVMs() async throws {
        var all = Set<String>()
        for generation in 0..<2 {
            let plugin = try AdaScriptPlugin(source: """
            @resource(id: "test.identifiers") struct GeneratedIDs { @export var text = ""; }
            @system(id: "test.identifiers.generate") class GenerateIDs {
                @res var ids: GeneratedIDs;
                func update(context) {
                    for (var i in 0..<32) { ids.text += Identifiers.uuid()+"|"; }
                }
            }
            """, name: "Identifiers" + String(generation))
            let world = World(name: "Identifiers")
            plugin.setup(in: AppWorlds(main: world))
            await world.runScheduler(.update)
            let store = try #require(world.getResource(RuntimeResourceStore.self))
            let field = try #require(store.payloads["test.identifiers"]?.values.first)
            guard case let .string(text) = field else { Issue.record("Expected generated strings"); return }
            let values = text.split(separator: "|").map(String.init)
            #expect(values.count == 32)
            for value in values { check(value); #expect(all.insert(value).inserted) }
            #expect(plugin.diagnostics.isEmpty)
        }
    }

    @Test func scriptableUsesTheSameHostAPI() async throws {
        let catalog = try AdaScriptObjectCatalog(schemas: [
            .init(identifier: "test.identifier.object", className: "IdentifierObject", version: 1, aliases: [], fields: ["value": .string("")])
        ], sources: [.init(path: "Identifier.ada", source: """
        @scriptable(id: "test.identifier.object") class IdentifierObject {
            @export var value = "";
            func update(context) { value = Identifiers.uuid(); }
        }
        """)])
        let descriptor = try #require(catalog.descriptors.first)
        let script = descriptor.make()
        let world = World(name: "Identifier scriptable")
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        world.spawn { ScriptableComponents(scripts: [script]) }
        var values = Set<String>()
        for _ in 0..<2 {
            await world.runScheduler(.update)
            guard case let .string(value) = script.readExportedField("value") else { Issue.record("Expected UUID"); return }
            check(value); #expect(values.insert(value).inserted)
        }
        #expect(catalog.diagnostics.isEmpty)
    }

    @Test func catalogDeclaresStringResultAndNoArguments() {
        let valid = AdaScriptAnalyzer.analyze(source: "func make() { var value: String = Identifiers.uuid(); }")
        #expect(valid.typeIssues.isEmpty)
        #expect(AdaScriptTypeEnvironment.standard.members["Identifiers"]?["uuid"]?.callable == AdaScriptCallableType(parameters: [], returnType: .string))
        #expect(AdaScriptTypeEnvironment.standard.values["Identifiers"] == .named("Identifiers"))
    }
}
