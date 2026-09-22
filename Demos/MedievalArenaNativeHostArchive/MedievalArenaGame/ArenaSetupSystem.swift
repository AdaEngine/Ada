import AdaEngine
import Foundation
import Math

@System
func SetupArena(_ commands: Commands) async {
    do {
        let floor = try await AssetsManager.load(Texture2D.self, at: "Assets/Tiles/tile_0000.png", from: .module)
        let wall = try await AssetsManager.load(Texture2D.self, at: "Assets/Tiles/tile_0014.png", from: .module)
        let knight = try await AssetsManager.load(Texture2D.self, at: "Assets/Tiles/tile_0096.png", from: .module)
        let knightOpen = try await AssetsManager.load(Texture2D.self, at: "Assets/Tiles/tile_0097.png", from: .module)
        let fighter = try await AssetsManager.load(Texture2D.self, at: "Assets/Tiles/tile_0098.png", from: .module)
        let elder = try await AssetsManager.load(Texture2D.self, at: "Assets/Tiles/tile_0100.png", from: .module)
        let sword = try await AssetsManager.load(Texture2D.self, at: "Assets/Tiles/tile_0103.png", from: .module)
        let textures = ArenaTextures(
            floor: floor,
            wall: wall,
            players: [knight, knightOpen, fighter, elder],
            sword: sword
        )
        commands.insertResource(textures)
        commands.spawn("Camera", bundle: Camera2D())

        let tileSize = Size(width: 48, height: 48)
        for row in -5...5 {
            for column in -9...9 {
                let isWall = row == -5 || row == 5 || column == -9 || column == 9
                commands.spawn(isWall ? "Arena wall" : "Arena floor") {
                    Transform(position: [Float(column) * 48, Float(row) * 48, isWall ? 0.2 : 0])
                    Sprite(texture: isWall ? wall : floor, size: tileSize)
                }
            }
        }

        var statusAttributes = TextAttributeContainer()
        statusAttributes.foregroundColor = .white
        statusAttributes.font = .system(size: 20)
        commands.spawn(
            "Network status",
            bundle: Text2D(
                textComponent: TextComponent(
                    text: AttributedText("NETWORK STARTING…", attributes: statusAttributes)
                ),
                transform: Transform(position: [-350, 286, 10])
            )
            .extend {
                ArenaStatusLabel()
            }
        )

        var hintAttributes = TextAttributeContainer()
        hintAttributes.foregroundColor = .white.opacity(0.82)
        hintAttributes.font = .system(size: 17)
        commands.spawn(
            "Controls hint",
            bundle: Text2D(
                textComponent: TextComponent(
                    text: AttributedText("WASD / ARROWS — MOVE     SPACE — SWORD", attributes: hintAttributes)
                ),
                transform: Transform(position: [-190, -286, 10])
            )
            .extend {
                ArenaHintLabel()
            }
        )
    } catch {
        print("[MedievalArena] asset setup failed: \(error)")
    }
}
