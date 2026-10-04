import AdaEngine

struct GardenPlayer: Component {
    var elapsed: Float = 0
}

struct GardenCamera: Component {
    var yaw: Float = 0.45
    var pitch: Float = 0.25
    var lastMouse = Point.zero
    var dragging = false
}

@MainActor
func makeGarden(in world: World, assetBundle: Bundle, includeCamera: Bool = true) throws {
    let device = unsafe RenderEngine.shared.renderDevice
    guard let model = try AssetsManager.loadSync(ModelAsset3D.self, at: "Assets/TestHumanoid.glb", from: assetBundle).asset else {
        throw AssetError.message("TestHumanoid could not be loaded")
    }
    let player = model.instantiate(in: world)
    player.components[GardenPlayer.self] = GardenPlayer()
    player.components[Transform.self] = Transform(position: [-0.7, 0, 0])
    if var animation = player.components[ModelAnimation3DComponent.self] {
        try animation.player.play("Idle", transitionDuration: 0)
        player.components[ModelAnimation3DComponent.self] = animation
    }
    let reference = model.instantiate(in: world)
    reference.components[Transform.self] = Transform(scale: [0.75, 0.75, 0.75], position: [1.2, 0, 1.5])
    if var animation = reference.components[ModelAnimation3DComponent.self] {
        try animation.player.play("Walk", transitionDuration: 0)
        animation.player.speed = 0.65
        reference.components[ModelAnimation3DComponent.self] = animation
    }
    guard let ribbonModel = try AssetsManager.loadSync(ModelAsset3D.self, at: "Assets/TwoBoneRibbon.glb", from: assetBundle).asset else {
        throw AssetError.message("TwoBoneRibbon could not be loaded")
    }
    let ribbon = ribbonModel.instantiate(in: world)
    ribbon.components[Transform.self] = Transform(position: [-2.5, 0.2, 1.3])
    if var animation = ribbon.components[ModelAnimation3DComponent.self] {
        try animation.player.play("Bend", transitionDuration: 0)
        ribbon.components[ModelAnimation3DComponent.self] = animation
    }

    let ground = PBRMaterial()
    ground.baseColorFactor = [0.22, 0.3, 0.24, 1]
    ground.roughnessFactor = 0.9
    world.spawn("Ground") {
        Mesh3DComponent(mesh: Mesh.generatePlane(size: [9, 9], renderDevice: device), materials: [ground])
        Transform()
    }
    let stone = PBRMaterial()
    stone.baseColorFactor = [0.65, 0.48, 0.3, 1]
    stone.roughnessFactor = 0.75
    let block = Mesh.generateCube(size: [0.55, 1.3, 0.55], renderDevice: device)
    let pillars: [Vector3] = [[-3, 0.65, -2], [3, 0.65, -2], [-3, 0.65, 3], [3, 0.65, 3]]
    for position in pillars {
        world.spawn("Pillar") {
            Mesh3DComponent(mesh: block, materials: [stone])
            Transform(position: position)
        }
    }
    let metal = PBRMaterial()
    metal.baseColorFactor = [0.7, 0.55, 0.25, 1]
    metal.metallicFactor = 0.8
    metal.roughnessFactor = 0.24
    world.spawn("Material Sphere") {
        Mesh3DComponent(mesh: Mesh.generateSphere(radius: 0.4, renderDevice: device), materials: [metal])
        Transform(position: [2.4, 0.4, 0.2])
    }
    world.spawn("Sun") {
        DirectionalLightComponent(radiance: [1, 0.88, 0.7], intensity: 4, shadowDistance: 18)
        Transform(rotation: Quat.euler([0.9, -0.4, 0]))
    }
    if includeCamera {
        var camera = Camera()
        camera.backgroundColor = Color(red: 0.12, green: 0.2, blue: 0.3)
        let cameraEntity = world.spawn("Camera", bundle: Camera3D(camera: camera))
        cameraEntity.components[GardenCamera.self] = GardenCamera()
    }
    print("[SkeletalGarden] loaded \(model.skins.count) skin, \(model.skins.first?.joints.count ?? 0) joints; clips=\(model.animationClips.map(\.name))")
}
