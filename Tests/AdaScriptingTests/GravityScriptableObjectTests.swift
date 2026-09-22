@testable import AdaApp
import AdaECS
import AdaInput
import AdaScene
import AdaScripting
import Foundation
import Testing

@Suite("Gravity scriptable objects", .serialized)
struct GravityScriptableObjectTests {
    @Test("Runs lifecycle and round trips detached exported state")
    @MainActor
    func lifecycleAndCoding() async throws {
        try registerRuntime()
        let script = try ScriptableObjectRegistry.make(named: "test.gravity-counter")
        let world = World(name: "Gravity scriptable lifecycle")
        let app = AppWorlds(main: world)
        InputPlugin().setup(in: app)
        ScriptableObjectPlugin().setup(in: app)
        world.insertResource(ScriptableBoundResource(value: 5))
        let entity = world.spawn {
            ScriptableBoundCounter()
            ScriptableComponents(scripts: [script])
        }

        await world.runScheduler(.update)
        let countAfterUpdate = try encodedCount(script)
        #expect(countAfterUpdate == 4)
        #expect(world.get(ScriptableBoundCounter.self, from: entity.id)?.value == 4)
        #expect(world.getResource(ScriptableBoundResource.self)?.value == 6)

        world.remove(ScriptableComponents.self, from: entity.id)
        await world.runScheduler(.update)
        let countAfterDestroy = try encodedCount(script)
        #expect(countAfterDestroy == 14)

        let aliasJSON = """
        {"scripts":[{"type":"LegacyCounter","version":1,"payload":{"count":7}}]}
        """
        let decoded = try JSONDecoder().decode(
            ScriptableComponents.self,
            from: Data(aliasJSON.utf8)
        )
        #expect(try encodedCount(#require(decoded.scripts.first)) == 7)

        let pending = try ScriptableObjectRegistry.make(named: "test.gravity-counter")
        let pendingEntity = world.spawn { ScriptableComponents(scripts: [pending]) }
        await world.runScheduler(.update)
        #expect(try encodedCount(pending) == 1)
        world.insert(ScriptableBoundCounter(), for: pendingEntity.id)
        await world.runScheduler(.update)
        #expect(try encodedCount(pending) == 4)
    }

    @MainActor
    private func registerRuntime() throws {
        RuntimeTypeRegistry.registerComponent(
            ScriptableBoundCounter.self,
            names: ["ScriptableBoundCounter", "test.scriptable-bound-counter"],
            makeDefault: { ScriptableBoundCounter() }
        )
        RuntimeTypeRegistry.registerResource(
            ScriptableBoundResource.self,
            names: ["ScriptableBoundResource", "test.scriptable-bound-resource"]
        )
        RuntimeResourceReflectionRegistry.register(
            ScriptableBoundResource.self,
            fields: [Self.resourceValueField]
        )
        try AdaScriptObjectRegistration.register(
            schemas: [Self.schema],
            sources: [Self.source],
            moduleName: "GravityScriptableObjectTests"
        )
    }

    private static let source = AdaScriptSource(
        path: "Counter.ada",
        source: """
        @scriptable(id: "test.gravity-counter", version: 2, aliases: ["LegacyCounter"])
        class CounterScript {
            @export var count = 1;
            @component(required: true) var target: ScriptableBoundCounter;
            @res var settings: ScriptableBoundResource;

            func ready(context) {
                count += 1;
            }

            func update(context) {
                count += 2;
                target.value += count;
                settings.value += 1;
            }

            func destroy(context) {
                count += 10;
            }
        }
        """
    )

    private static let schema = AdaScriptObjectSchema(
        identifier: "test.gravity-counter",
        className: "CounterScript",
        version: 2,
        aliases: ["LegacyCounter"],
        bindings: [
            AdaScriptObjectBinding(
                kind: .component(required: true),
                propertyName: "target",
                typeName: "ScriptableBoundCounter"
            ),
            AdaScriptObjectBinding(
                kind: .resource(optional: false),
                propertyName: "settings",
                typeName: "ScriptableBoundResource"
            )
        ],
        fields: ["count": .int(1)]
    )

    private func encodedCount(_ script: ScriptableObject) throws -> Int? {
        let data = try JSONEncoder().encode(ScriptableComponents(scripts: [script]))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scripts = try #require(object["scripts"] as? [[String: Any]])
        let payload = try #require(scripts.first?["payload"] as? [String: Any])
        return payload["count"] as? Int
    }

    @safe
    private static let resourceValueField = unsafe ReflectedComponentField(
        key: "value",
        label: "value",
        kind: .float,
        isWritable: true,
        accepts: { ComponentReflection.accepts($0, for: Double.self) },
        read: { _ in nil },
        write: { _, _ in nil },
        readPointer: { pointer in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptableBoundResource.self)
            return ComponentReflection.read(unsafe resource.pointee.value)
        },
        writePointer: { pointer, value in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptableBoundResource.self)
            return unsafe ComponentReflection.write(value, to: &resource.pointee.value)
        }
    )
}

@Component
private struct ScriptableBoundCounter {
    var value: Double = 0
}

private struct ScriptableBoundResource: Resource {
    var value: Double
}
