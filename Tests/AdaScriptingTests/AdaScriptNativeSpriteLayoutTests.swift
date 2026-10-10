#if canImport(GravityAOT)
@testable import AdaApp
import AdaECS
import AdaScriptAOTFixture
import AdaScriptCompilerCore
@testable import AdaScripting
import AdaSprite
import AdaTilemap
import GravityAOT
import Math
import Testing

@MainActor
@Suite(.serialized)
struct AdaScriptNativeSpriteLayoutTests {
    @Test("Native component host uses the same detached constructor and writable fields")
    func nativeConstructor() throws {
        RuntimeTypeRegistry.registerComponent(Sprite.self, names: ["Sprite"])
        let scope = NativeCallbackScope()
        let factory = NativeComponentFactory(scope: scope, components: [])
        let arguments: [NativeValue] = [
            .null, .null, .null, .null, .list([.integer(160), .integer(80)]),
            .list([.double(-0.5), .double(-0.5)]), .list([.string("sliced"), .integer(8), .integer(8), .integer(8), .integer(8)]),
        ]
        let value = try #require(try factory.call("makeNamed", arguments: [.string("Sprite"), .list(arguments)]))
        guard case let .host(host) = value, let draft = host as? NativeComponentDraft else {
            Issue.record("Missing native Sprite draft")
            return
        }
        #expect(try draft.write("imageMode", value: .list([.string("tiled"), .boolean(true), .boolean(false), .double(2)])))
        let sprite = try #require(try draft.take() as? Sprite)
        #expect(sprite.anchor == .bottomLeft)
        #expect(sprite.size == Size(width: 160, height: 80))
        #expect(sprite.imageMode == .tiled(tileX: true, tileY: false, scale: 2))
        #expect(throws: AdaScriptError.self) { try draft.take() }
    }

    @Test("Native tile edits remain deferred and reject expired capabilities")
    func nativeTileOrientation() throws {
        let pointer = try #require(ada_native_hosts_get_module())
        let module = unsafe try NativeModule(module: pointer)
        let scope = NativeCallbackScope()
        let world = World()
        let map = TileMap()
        let sourceID = map.tileSet.addTileSource(TileEntityAtlasSource())
        map.layers[0].setCell(at: [2, 3], sourceId: sourceID, atlasCoordinates: [0, 0])
        let entity = world.spawn { TileMapComponent(tileMap: map, tileDisplaySize: Size(width: 24, height: 16)) }
        let commands = Commands(entities: world.entities, commandsQueue: world.commandQueue)
        let host = NativeWorldHost(scope: scope, commands: commands, navigator: nil, components: [], module: module)
        let arguments: [NativeValue] = [.integer(Int64(entity.id)), .integer(0), .list([.integer(2), .integer(3)]), .integer(7)]
        let accepted = try host.call("setTileOrientation", arguments: arguments)
        if case .boolean(true)? = accepted {} else { Issue.record("Native orientation command was not accepted") }
        #expect(map.layers[0].getCellOrientation(at: [2, 3]) == .identity)
        world.flush()
        #expect(map.layers[0].getCellOrientation(at: [2, 3]) == .mirrorXRotate270)
        scope.isActive = false
        #expect(throws: AdaScriptError.self) { try host.call("setTileOrientation", arguments: arguments) }
    }

    @Test("Native source preparation resolves new Sprite arguments while retaining shared factories")
    func sourcePreparation() throws {
        let source = """
        @system class Layout {
            func update(context) {
                context.world.spawn([Sprite(anchor: SpriteAnchor.topCenter, imageMode: SpriteImageMode.tiled(true, false, 2))]);
            }
        }
        """
        let parameters = Sprite.runtimeComponentConstructor.parameters.map(\.name)
        let prepared = try AdaScriptNativeSourceBuilder.prepare(sources: [.init(path: "Layout.ada", source: source)], constructors: ["Sprite": parameters])
        #expect(prepared[0].source.contains(AdaScriptSpriteLayoutLibrary.nativeSource))
        #expect(prepared[1].source.contains("makeNamed(\"Sprite\", [null, null, null, null, null, [0.0, 0.5], AdaSpriteImageModeTiled(true, false, 2)])"))
        let defaults = AdaScriptSpriteLayoutLibrary.lowerForNative("var a = SpriteAnchor(); var b = SpriteSliceBorder(8); var c = SpriteImageMode.tiled();")
        #expect(defaults.contains("SpriteAnchor(0, 0)"))
        #expect(defaults.contains("SpriteSliceBorder(8, 0, 0, 0)"))
        #expect(defaults.contains("AdaSpriteImageModeTiled(true, true, 1)"))
        let quoted = "var text = \"SpriteAnchor.center\"; // TileOrientation.rotate90"
        #expect(AdaScriptSpriteLayoutLibrary.lowerForNative(quoted) == quoted)
    }
}
#endif
