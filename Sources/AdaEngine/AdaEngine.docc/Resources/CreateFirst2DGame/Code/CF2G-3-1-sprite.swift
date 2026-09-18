import AdaEngine

struct FirstScene: Plugin {
    func setup(in app: AppWorlds) {
        let camera = Camera()
        camera.backgroundColor = Color(45 / 255, 171 / 255, 255 / 255, 1)
        app.spawn(bundle: Camera2D(camera: camera))

        app.spawn("Player")
    }
}
