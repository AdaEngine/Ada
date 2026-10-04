import AdaEngine
import Foundation

#if os(Android)
@_cdecl("ada_android_start")
public func startAndroidGarden() {
    AndroidRuntime.start { SkeletalGarden() }
}
#else
@main
private enum GardenMain {
    static func main() async throws {
        try await SkeletalGarden.main()
    }
}
#endif
struct SkeletalGarden: App {
    var body: some AppScene {
        DefaultAppWindow(assetBundle: gardenBundle)
            .addPlugins(GardenPlugin())
            .window(with: UIWindow.Configuration(
                title: "AdaEngine · Skeletal Garden · WASD / Shift / drag to orbit",
                frame: Rect(x: 120, y: 100, width: 1100, height: 760)
            ))
    }
}

private var gardenBundle: Foundation.Bundle {
    #if os(Android)
    AndroidResourceBundle.bundle(named: "AdaEngine_SkeletalGarden")
    #else
    .module
    #endif
}

struct GardenPlugin: Plugin {
    func setup(in app: AppWorlds) {
        GardenPlayer.registerComponent()
        GardenCamera.registerComponent()
        app.addSystem(StartupGardenSystem.self, on: .startup)
        app.addSystem(UpdateGardenSystem.self, on: .update)
        #if os(macOS)
        installCapture(in: app)
        #endif
    }
}

struct GardenPlayer: Component {
    var elapsed: Float = 0
}

struct GardenCamera: Component {
    var yaw: Float = 0.45
    var pitch: Float = 0.25
    var lastMouse = Point.zero
    var dragging = false
}

@System
@MainActor
func StartupGarden(_ context: WorldUpdateContext) {
    do { try makeGarden(in: context.world) } catch { gardenLog("[SkeletalGarden] startup failed: \(error)") }
}

@MainActor
private func makeGarden(in world: World) throws {
    let device = unsafe RenderEngine.shared.renderDevice
    guard let model = try AssetsManager.loadSync(ModelAsset3D.self, at: "Assets/TestHumanoid.glb", from: gardenBundle).asset else {
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
    guard let ribbonModel = try AssetsManager.loadSync(ModelAsset3D.self, at: "Assets/TwoBoneRibbon.glb", from: gardenBundle).asset else {
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
    var camera = Camera()
    camera.backgroundColor = Color(red: 0.12, green: 0.2, blue: 0.3)
    let cameraEntity = world.spawn("Camera", bundle: Camera3D(camera: camera))
    cameraEntity.components[GardenCamera.self] = GardenCamera()
    gardenLog("[SkeletalGarden] loaded \(model.skins.count) skin, \(model.skins.first?.joints.count ?? 0) joints; clips=\(model.animationClips.map(\.name))")
}

@PlainSystem
struct UpdateGardenSystem {
    @Query<GardenPlayer, Ref<Transform>, Ref<ModelAnimation3DComponent>> private var players
    @Query<Ref<GardenPlayer>> private var playerTimers
    @Query<Ref<GardenCamera>, Ref<Transform>> private var cameras
    @Res<Input> private var input
    @Res<DeltaTime> private var time
    #if os(Android)
    private let autoplay = true
    #else
    private let autoplay = ProcessInfo.processInfo.arguments.contains("--autoplay")
    #endif
    private let poseProof = ProcessInfo.processInfo.arguments.contains("--pose-proof")

    init(world _: World) {}

    func update(context _: UpdateContext) {
        var focus = Vector3(0, 1, 0)
        playerTimers.forEach { $0.elapsed += time.deltaTime }
        players.forEach { (state: GardenPlayer, transform: Ref<Transform>, animation: Ref<ModelAnimation3DComponent>) in
            var direction = Vector3.zero
            if input.isKeyPressed(.w) { direction.z += 1 }
            if input.isKeyPressed(.s) { direction.z -= 1 }
            if input.isKeyPressed(.a) { direction.x -= 1 }
            if input.isKeyPressed(.d) { direction.x += 1 }
            let running = input.isKeyPressed(.shift) || autoplay && Int(state.elapsed / 3).isMultiple(of: 2)
            if autoplay { direction = [Math.cos(state.elapsed * 0.6), 0, Math.sin(state.elapsed * 0.6)] }
            if poseProof { direction = [0, 0, 1] }
            let moving = direction.length > 0.01
            let clip = moving ? (running ? "Run" : "Walk") : "Idle"
            if animation.player.clipIndex.map({ animation.player.clips[$0].name }) != clip {
                do {
                    try animation.player.play(clip)
                    #if os(Android)
                    gardenLog("[SkeletalGarden] animation=\(clip)")
                    #endif
                } catch { gardenLog("[SkeletalGarden] \(error)") }
            }
            if moving && !poseProof {
                direction = direction.normalized
                transform.position += direction * time.deltaTime * (running ? 2.2 : 1.1)
                transform.position.x = min(max(transform.position.x, -2.4), 2.4)
                transform.position.z = min(max(transform.position.z, -2.4), 2.4)
                transform.rotation = Quat(axis: .up, angle: Math.atan2(direction.x, direction.z))
            }
            focus = transform.position + [0, 1, 0]
        }
        cameras.forEach { (orbit: Ref<GardenCamera>, transform: Ref<Transform>) in
            #if os(Android)
                let contact = input.getTouches().first { $0.phase == .began || $0.phase == .moved }
                let mouse = contact?.location ?? orbit.lastMouse
                let dragging = contact != nil
            #else
                let mouse = input.getMousePosition()
                let dragging = input.isMouseButtonPressed(.left)
            #endif
            if dragging && orbit.dragging {
                orbit.yaw -= (mouse.x - orbit.lastMouse.x) * 0.008
                orbit.pitch = min(max(orbit.pitch + (mouse.y - orbit.lastMouse.y) * 0.006, 0.1), 0.8)
            }
            orbit.lastMouse = mouse
            orbit.dragging = dragging
            let distance: Float = 6
            let eye = focus + Vector3(Math.sin(orbit.yaw) * distance, Math.sin(orbit.pitch) * distance + 0.5, -Math.cos(orbit.yaw) * distance)
            let forward = (focus - eye).normalized
            let right = Vector3.up.cross(forward).normalized
            let up = forward.cross(right)
            let matrix = Transform3D(Vector4(right, 0), Vector4(up, 0), Vector4(forward, 0), Vector4(eye, 1))
            transform.wrappedValue = Transform(matrix: matrix)
        }
    }
}

private func gardenLog(_ message: String) {
    #if os(Android)
    AndroidRuntime.log(message)
    #else
    print(message)
    #endif
}
