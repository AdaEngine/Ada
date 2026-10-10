import AdaECS
import AdaScriptCompilerCore
import AdaSprite
import Math
import Testing

@testable import AdaApp
@testable import AdaScripting
@testable import AdaTilemap

@MainActor
@Suite("AdaScript sprite layout authoring", .serialized)
struct AdaScriptSpriteLayoutTests {
    @Test("VM factories construct every sprite mode and preserve legacy defaults")
    func constructors() async throws {
        try #require(Sprite.runtimeComponentConstructor.parameters.map(\.name) == ["texture", "tintColor", "flipX", "flipY", "size", "anchor", "imageMode"])
        RuntimeTypeRegistry.registerComponent(Sprite.self, names: ["Sprite"])
        let plugin = try AdaScriptPlugin(
            source: """
                @system class Layout {
                    func update(context) {
                        context.world.spawn([Sprite()]);
                        context.world.spawn([Sprite(size: [160, 80], anchor: SpriteAnchor.bottomLeft, imageMode: SpriteImageMode.fit)]);
                        context.world.spawn([Sprite(anchor: SpriteAnchor(0.25, -0.75), imageMode: SpriteImageMode.fill)]);
                        context.world.spawn([Sprite(imageMode: SpriteImageMode.sliced(SpriteSliceBorder(2, 3, 4, 5)))]);
                        context.world.spawn([Sprite(imageMode: SpriteImageMode.tiled(false, true, 2))]);
                    }
                }
                """
        )
        let world = World()
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        let sprites = world.getEntities().compactMap { $0.components[Sprite.self] }
        #expect(plugin.diagnostics.isEmpty)
        #expect(sprites.count == 5)
        #expect(sprites.contains { $0.imageMode == .stretch && $0.size == nil && $0.anchor == .center })
        #expect(sprites.contains { $0.imageMode == .fit && $0.size == Size(width: 160, height: 80) && $0.anchor == .bottomLeft })
        #expect(sprites.contains { $0.imageMode == .fill && $0.anchor == SpriteAnchor(x: 0.25, y: -0.75) })
        #expect(sprites.contains { $0.imageMode == .sliced(SpriteSliceBorder(top: 2, left: 3, bottom: 4, right: 5)) })
        #expect(sprites.contains { $0.imageMode == .tiled(tileX: false, tileY: true, scale: 2) })
    }

    @Test("Query fields write detached layout values back to the production component")
    func queryWrites() async throws {
        RuntimeTypeRegistry.registerComponent(Sprite.self, names: ["Sprite"])
        let plugin = try AdaScriptPlugin(
            source: """
                @system class Layout {
                    @query(Sprite) var sprites;
                    func update(context) {
                        for (var entity in sprites) {
                            entity.sprite.anchor = SpriteAnchor.topRight;
                            entity.sprite.size = [90, 45];
                            entity.sprite.imageMode = SpriteImageMode.tiled(true, false, 0.5);
                        }
                    }
                }
                """
        )
        let world = World()
        let entity = world.spawn { Sprite() }
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        let sprite = try #require(world.get(Sprite.self, from: entity.id))
        #expect(plugin.diagnostics.isEmpty)
        #expect(sprite.anchor == .topRight)
        #expect(sprite.size == Size(width: 90, height: 45))
        #expect(sprite.imageMode == .tiled(tileX: true, tileY: false, scale: 0.5))
    }

    @Test("Invalid detached layout values are rejected without changing the component")
    func invalidValues() {
        var anchor = SpriteAnchor.bottomLeft
        #expect(!ComponentReflection.write(.array([.double(.infinity), .int(0)]), to: &anchor))
        #expect(anchor == .bottomLeft)
        var mode = SpriteImageMode.fit
        for value: ReflectedFieldValue in [
            .string("unknown"), .array([.string("tiled"), .bool(true), .bool(true), .int(0)]),
            .array([.string("sliced"), .int(-1), .int(0), .int(0), .int(0)]),
        ] {
            #expect(!ComponentReflection.write(value, to: &mode))
            #expect(mode == .fit)
        }
    }

    @Test("Tile orientation constants reach the deferred world command and invalidate the layer")
    func tileOrientation() async throws {
        RuntimeTypeRegistry.registerComponent(TileMapComponent.self, names: ["TileMapComponent"])
        let map = TileMap()
        let source = TileEntityAtlasSource()
        let sourceID = map.tileSet.addTileSource(source)
        map.layers[0].setCell(at: [2, 3], sourceId: sourceID, atlasCoordinates: [0, 0])
        let world = World()
        let entity = world.spawn { TileMapComponent(tileMap: map, tileDisplaySize: Size(width: 24, height: 16)) }
        let revision = map.layers[0].updateRevision
        let plugin = try AdaScriptPlugin(
            source: """
                @system class Rotate {
                    @query(TileMapComponent) var maps;
                    func update(context) {
                        for (var entity in maps) {
                            context.world.setTileOrientation(entity.id, 0, [2, 3], TileOrientation.mirrorXRotate90);
                        }
                    }
                }
                """
        )
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(plugin.diagnostics.isEmpty)
        #expect(world.get(TileMapComponent.self, from: entity.id)?.tileMap.layers[0].getCellOrientation(at: [2, 3]) == .mirrorXRotate90)
        #expect(map.layers[0].updateRevision > revision)
    }
}
