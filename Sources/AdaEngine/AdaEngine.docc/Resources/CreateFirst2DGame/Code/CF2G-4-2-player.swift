import AdaEngine

struct FirstScene: Plugin {
    func setup(in app: AppWorlds) {
        let camera = Camera()
        camera.backgroundColor = Color(45 / 255, 171 / 255, 255 / 255, 1)
        app.spawn(bundle: Camera2D(camera: camera))

        let spriteSheetImage = try! AssetsManager.loadSync(Image.self, at: "@res://characters_packed.png").asset!
        let spriteSheet = TextureAtlas(from: spriteSheetImage, size: [20, 23], margin: [4, 1])

        app.spawn("Player") {
            Sprite(
                texture: spriteSheet[7, 1],
                size: Size(width: 24, height: 24)
            )
            Transform()
            PlayerComponent()
        }
    }
}

@Component
struct PlayerComponent {}

@System
func PlayerMovement() {

}
