import AdaScriptCompilerCore
import Testing

@Suite("Native AdaScript source preparation")
struct AdaScriptNativeSourceTests {
    @Test("Preserves schema declarations while resolving named and nested component calls")
    func constructors() throws {
        let source = """
            @component(id: "position") struct Position { @export var x = 0.0; }
            @system class Game {
                func update(context) {
                    context.world.spawn([Transform(scale: [2.0, 2.0, 2.0], position: [1.0, 0.0, 0.0]), Position(3.0)]);
                }
            }
            """
        let result = try AdaScriptNativeSourceBuilder.prepare(sources: [.init(path: "Game.ada", source: source)], constructors: ["Transform": ["position", "rotation", "scale"]])
        #expect(result[1].source.contains("@component(id: \"position\") struct Position"))
        #expect(result[1].source.contains("makeNamed(\"Transform\", [[1.0, 0.0, 0.0], null, [2.0, 2.0, 2.0]])"))
        #expect(result[1].source.contains("makeNamed(\"Position\", [3.0])"))
        #expect(throws: (any Error).self) {
            try AdaScriptNativeSourceBuilder.prepare(sources: [.init(path: "Bad.ada", source: "func main() { return Transform(unknown: 1); }")], constructors: ["Transform": ["position"]])
        }
    }

    @Test("Async RPC handlers preserve await and receive detached sender parameters")
    func asyncRPC() throws {
        let source = """
            @system class Network {
                @rpc(id: "test.async.move") async func Move(@network_field(1) amount: Int = 0) { await Tasks.nextFrame(); var sender = source; }
                func update(context) {}
            }
            """
        let prepared = try AdaScriptNativeSourceBuilder.prepare(sources: [.init(path: "Network.ada", source: source)], constructors: [:])
        #expect(prepared[1].source.contains("async func Move(source, amount)"))
        #expect(prepared[1].source.contains("await Tasks.nextFrame()"))
        let commands = try AdaScriptSchemaParser.parseNetworkCommands(sources: [.init(path: "Network.ada", source: source)])
        #expect(commands.first?.id == "test.async.move")
        #expect(commands.first?.fields.first?.name == "amount")
    }

    @Test("RPC handlers receive authenticated source and keep schema metadata")
    func rpc() throws {
        let source = """
            @system class Network {
                @rpc(id: "test.move") func Move(@network_field(1) amount: Int = 0) { var sender = source; }
                func update(context) { multiplayer.send(Move(27)); }
            }
            """
        let prepared = try AdaScriptNativeSourceBuilder.prepare(sources: [.init(path: "Network.ada", source: source)], constructors: [:])
        #expect(prepared[1].source.contains("@rpc(id: \"test.move\") func Move(source, amount)"))
        #expect(prepared[1].source.contains("__adaNetworkFactory.makeNamed(\"Move\", [27])"))
    }
}
