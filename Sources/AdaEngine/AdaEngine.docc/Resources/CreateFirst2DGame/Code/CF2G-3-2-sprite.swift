import AdaEngine

struct FirstScene: Plugin {
    func setup(in app: AppWorlds) {
        let camera = Camera()
        camera.backgroundColor = Color(45 / 255, 171 / 255, 255 / 255, 1)
        app.spawn(bundle: Camera2D(camera: camera))

        let spriteSheetImage = try! AssetsManager.loadSync(Image.self, at: "@res://characters_packed.png").asset!

        app.spawn("Player")
    }
}
