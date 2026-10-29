import AdaApp
@testable import AdaECS
import AdaScripting
import Testing

@MainActor
@Suite("AdaScript native system implementations", .serialized)
struct AdaScriptNativeSystemTests {
    private static let source = """
    @access(write: [NativeOverrideProbe], read: [])
    @system(id: "before")
    class Before {
        @query(NativeOverrideProbe) var rows;
        func update(context) { for (var row in rows) row.nativeOverrideProbe.value += 1; }
    }
    @after(id: "before")
    @before(id: "after")
    @access(write: [NativeOverrideProbe], read: [])
    @system(id: "replaced")
    class Replaced {
        @query(NativeOverrideProbe) var rows;
        func update(context) { for (var row in rows) row.nativeOverrideProbe.value = -1000; }
    }
    @access(write: [NativeOverrideProbe], read: [])
    @system(id: "after")
    class After {
        @query(NativeOverrideProbe) var rows;
        func update(context) { for (var row in rows) row.nativeOverrideProbe.value += 1; }
    }
    """

    private func plugin() throws -> AdaScriptPlugin {
        NativeOverrideProbe.registerComponent()
        return try AdaScriptPlugin(
            sources: [.init(path: "Main.ada", source: Self.source)], name: "NativeOverrides",
            nativeSystemFactories: ["replaced": { NativeOverrideSystem(world: $0) }]
        )
    }

    @Test func replacesOnlyCallbackPreservingOrderingIdentityAndAccess() async throws {
        let plugin = try plugin()
        let world = World()
        plugin.setup(in: AppWorlds(main: world))
        let entity = world.spawn { NativeOverrideProbe(value: 1) }
        await world.runScheduler(.update)
        #expect(world.get(NativeOverrideProbe.self, from: entity.id)?.value == 21)
        let scheduler = try #require(world.schedulers.getScheduler(.update))
        let node = try #require(scheduler.systemGraph.nodes.first { $0.name.hasSuffix(":replaced") })
        #expect(node.name == "AdaScripting.System.15:NativeOverrides8:replaced")
        var readers = SystemAccessSet()
        readers.addComponentRead(NativeOverrideProbe.self)
        #expect(!node.queries.access.isCompatible(with: readers))
        #expect(plugin.diagnostics.isEmpty)
    }

    @Test func factoryCreatesIndependentQueryStateForEachWorld() async throws {
        let plugin = try plugin()
        let left = World(), right = World()
        plugin.setup(in: AppWorlds(main: left))
        plugin.setup(in: AppWorlds(main: right))
        let a = left.spawn { NativeOverrideProbe(value: 1) }
        let b = right.spawn { NativeOverrideProbe(value: 5) }
        await left.runScheduler(.update)
        await right.runScheduler(.update)
        await left.runScheduler(.update)
        #expect(left.get(NativeOverrideProbe.self, from: a.id)?.value == 221)
        #expect(right.get(NativeOverrideProbe.self, from: b.id)?.value == 61)
        #expect(plugin.diagnostics.isEmpty)
    }

    @Test func reloadRetainsNativeImplementation() async throws {
        let plugin = try plugin()
        let world = World()
        let app = AppWorlds(main: world)
        plugin.setup(in: app)
        let entity = world.spawn { NativeOverrideProbe(value: 1) }
        await world.runScheduler(.update)
        try await plugin.reload(sources: [.init(path: "Main.ada", source: Self.source)], in: app)
        await world.runScheduler(.update)
        #expect(world.get(NativeOverrideProbe.self, from: entity.id)?.value == 221)
        #expect(plugin.diagnostics.isEmpty)
    }

    @Test func rejectsUnknownNativeSystemIdentifier() throws {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptPlugin(
                sources: [.init(path: "Empty.ada", source: "var marker = 0;")], name: "UnknownNative",
                nativeSystemFactories: ["missing": { NativeOverrideSystem(world: $0) }]
            )
        }
    }

    @Test func reportsFactoryFailureInsteadOfRunningScriptFallback() async throws {
        NativeOverrideProbe.registerComponent()
        let plugin = try AdaScriptPlugin(
            sources: [.init(path: "Main.ada", source: Self.source)], name: "FactoryFailure",
            nativeSystemFactories: ["replaced": { _ in throw AdaScriptError.invalidManifest("schema mismatch") }]
        )
        let world = World()
        plugin.setup(in: AppWorlds(main: world))
        let entity = world.spawn { NativeOverrideProbe(value: 1) }
        await world.runScheduler(.update)
        #expect(world.get(NativeOverrideProbe.self, from: entity.id)?.value == 3)
        #expect(plugin.diagnostics.count == 1)
        #expect(plugin.diagnostics.first?.contains("schema mismatch") == true)
    }
}

@Component
private struct NativeOverrideProbe {
    var value: Int
}

private struct NativeOverrideSystem: System {
    private let rows = Query<Ref<NativeOverrideProbe>>()
    init(world: World) {}
    var queries: SystemQueries { SystemQueries(queries: [rows]) }
    func update(context: UpdateContext) async {
        for row in rows { row.value *= 10 }
    }
}
