@_spi(Internal) import AdaApp
@_spi(Scripting) import AdaECS
@_spi(Scripting) @testable import AdaScene
import Testing

@testable import AdaScripting

#if canImport(GravityAOT)
import AdaScriptAOTFixture
import GravityAOT
#endif

@MainActor
@Suite("AdaScript 3D decal bridge", .serialized)
struct AdaScriptDecalBridgeTests {
    @Test func interpretedCallbacksCanPollQueuedAndRejectedCommands() async throws {
        let world = World()
        let commands = Decal3DCommands()
        world.insertResource(commands)
        let plugin = try AdaScriptPlugin(source: """
            @system(id: "decal.probe")
            class Probe {
                var pending = "";
                func update(context) {
                    var invalid = context.world.placeDecal(-1, "@res://Paint.png", [[0, 0, 0], [0, 0, 1], [1, 1, 1]], []);
                    var failure = context.world.decalResult(invalid);
                    assert(failure.errorCode() == "invalidArguments", "The rejected request must report invalidArguments");
                    assert(context.world.decalResult(invalid).errorCode() == "unknownRequest", "A rejected result must be consumed");
                    pending = context.world.placeDecal(1, "@res://Paint.png", [[0, 0, 0], [0, 0, 1], [1, 1, 1]], []);
                    assert(context.world.decalResult(pending) == null, "The queued request must return null while pending");
                }
            }
            """)
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(plugin.diagnostics.isEmpty)
        let request = try #require(commands.next())
        #expect(request.operation.receiver == 1)
        #expect(request.operation.images?.color == "@res://Paint.png")
        #expect(commands.takeResult(request.id) == nil)
    }

    #if canImport(GravityAOT)
    @Test func nativeCallbacksUseTheSameResultAndQueue() throws {
        let pointer = try #require(ada_native_hosts_get_module())
        let module = unsafe try NativeModule(module: pointer)
        let probe = try module.makeInstance(type: "HostProbe")
        let world = World()
        let scope = NativeCallbackScope()
        let queue = Decal3DCommands()
        let host = NativeWorldHost(
            scope: scope,
            commands: Commands(entities: world.entities, commandsQueue: world.commandQueue),
            navigator: nil,
            components: [],
            module: module,
            decals: queue
        )
        let context = NativeSystemContext(scope: scope, deltaTime: 0, world: host)
        let value = try module.invoke(probe, method: "decals", arguments: [.host(context)])
        #expect(value.literal == .string("invalidArguments"))
        let placement = try #require(queue.next())
        #expect(placement.operation.images?.color == "@res://Paint.png")
    }
    #endif
}
