@testable import AdaApp
import AdaECS
import AdaScripting
import AdaUtils
import Math
import Testing

@Suite("Annotation-driven Gravity safety", .serialized)
struct AdaScriptPluginSafetyTests {
    @Test("Reports an unknown native component during plugin setup")
    @MainActor
    func reportsUnknownComponentDuringSetup() async throws {
        let plugin = try AdaScriptPlugin(source: Self.missingComponentSource)
        let app = AppWorlds(main: World(name: "Missing Component Test"))
        app.addPlugin(plugin)

        try await app.build()

        #expect(plugin.diagnostics == ["Unknown component 'MissingComponent' in query 0 of system 'broken'"])
    }

    @Test("Resolves components registered by an earlier plugin setup")
    @MainActor
    func resolvesComponentsDuringOrderedPluginSetup() async throws {
        let plugin = try AdaScriptPlugin(source: Self.deferredComponentSource)
        let world = World(name: "Deferred Component Registration Test")
        world.spawn { DeferredScriptComponent() }
        let app = AppWorlds(main: world)
        app.addPlugin(DeferredComponentRegistrationPlugin())
        app.addPlugin(plugin)

        try await app.build()
        await world.runScheduler(.update)

        #expect(plugin.diagnostics.isEmpty)
    }

    @Test("Rejects non-finite and out-of-range floating-point writes")
    @MainActor
    func rejectsInvalidFloatingPointWrites() async throws {
        ScriptNumericFields.registerComponent()
        let plugin = try AdaScriptPlugin(source: Self.invalidFloatSource)
        let world = World(name: "Invalid Gravity Float Test")
        let entity = world.spawn {
            ScriptNumericFields(
                scalar: 1,
                vector: Vector2(2, 3),
                quaternion: Quat(x: 0, y: 0, z: 0, w: 1),
                color: .white,
                double: 5
            )
        }

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        let fields = try #require(world.get(ScriptNumericFields.self, from: entity.id))
        #expect(fields.scalar == 1)
        #expect(fields.vector == Vector2(2, 3))
        #expect(fields.quaternion == Quat(x: 0, y: 0, z: 0, w: 1))
        #expect(fields.color == .white)
        #expect(fields.double == 42)
        #expect(plugin.diagnostics.count == 4)
    }

    @Test("Rejects a list when any member is unsupported")
    @MainActor
    func rejectsUnsupportedListMembersAtomically() async throws {
        ScriptNumericFields.registerComponent()
        let plugin = try AdaScriptPlugin(source: Self.unsupportedListMemberSource)
        let world = World(name: "Unsupported Gravity List Member Test")
        let entity = world.spawn {
            ScriptNumericFields(
                scalar: 1,
                vector: Vector2(2, 3),
                quaternion: Quat(x: 0, y: 0, z: 0, w: 1),
                color: .white,
                double: 5
            )
        }

        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        #expect(world.get(ScriptNumericFields.self, from: entity.id)?.vector == Vector2(2, 3))
        #expect(plugin.diagnostics == ["Invalid value for 'scriptNumericFields.vector'"])
    }

    private static let missingComponentSource = """
    @system(scheduler: "update", id: "broken")
    class BrokenSystem {
        @query(MissingComponent)
        var missing;

        func update(context) {}
    }
    """

    private static let deferredComponentSource = """
    @system(scheduler: "update", id: "deferred")
    class DeferredSystem {
        @query(DeferredScriptComponent)
        var components;

        func update(context) {
            for (var entity in components) {}
        }
    }
    """

    private static let invalidFloatSource = """
    @system(scheduler: "update", id: "invalid.float")
    class InvalidFloatSystem {
        @query(ScriptNumericFields)
        var entities;

        func update(context) {
            var infinity = Float.max * Float.max;
            var notANumber = infinity - infinity;
            for (var entity in entities) {
                entity.scriptNumericFields.set("scalar", Float.max);
                entity.scriptNumericFields.set("vector", [1, infinity]);
                entity.scriptNumericFields.set("quaternion", [0, 0, notANumber, 1]);
                entity.scriptNumericFields.set("color", [1, 1, 1, infinity]);
                entity.scriptNumericFields.set("double", 42);
            }
        }
    }
    """

    private static let unsupportedListMemberSource = """
    class UnsupportedValue {}

    @system(scheduler: "update", id: "invalid.list")
    class InvalidListSystem {
        @query(ScriptNumericFields)
        var entities;

        func update(context) {
            for (var entity in entities) {
                entity.scriptNumericFields.set("vector", [UnsupportedValue(), 3, 4]);
            }
        }
    }
    """
}

private struct DeferredScriptComponent: Component {}

private struct DeferredComponentRegistrationPlugin: Plugin {
    @MainActor
    func setup(in app: borrowing AppWorlds) {
        DeferredScriptComponent.registerComponent()
    }
}

@Component
private struct ScriptNumericFields: Codable, Sendable {
    var scalar: Float
    var vector: Vector2
    var quaternion: Quat
    var color: Color
    var double: Double
}
