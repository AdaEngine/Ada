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
    static func main() async throws { try await SkeletalGarden.main() }
}
#endif
struct SkeletalGarden: App {
    init() {
        if ProcessInfo.processInfo.arguments.contains("--metal") { unsafe RenderEngine.configurations.preferredBackend = .metal }
        if ProcessInfo.processInfo.arguments.contains("--webgpu") {
            unsafe RenderEngine.configurations.preferredBackend = .webgpu
        }
        if ProcessInfo.processInfo.arguments.contains("--spatial-proof") {
            unsafe RenderEngine.configurations.upscaling = .spatial(renderScale: 0.75)
        }
    }

    var body: some AppScene {
        DefaultAppWindow(assetBundle: gardenBundle)
            .addPlugins(GardenPlugin())
            .window(with: UIWindow.Configuration(
                title: "AdaEngine · Skeletal Garden · WASD / Shift / Space / drag to orbit",
                frame: Rect(x: 120, y: 100, width: 1100, height: 760)
            ))
    }
}

var gardenBundle: Foundation.Bundle {
    #if os(Android)
    AndroidResourceBundle.bundle(named: "AdaEngine_SkeletalGarden")
    #else
    .module
    #endif
}

struct GardenPlugin: Plugin {
    func setup(in app: AppWorlds) {
        app.addPlugin(Physics3DPlugin())
        GardenPlayer.registerComponent()
        GardenCamera.registerComponent()
        app.addSystem(StartupGardenSystem.self, on: .startup)
        app.addSystem(GardenInputSystem.self, on: .update)
        app.addSystem(GardenRenderQualitySystem.self, on: .update)
        app.addSystem(GardenLocalLightingSystem.self, on: .postUpdate)
        app.addSystem(GardenTemporalValidationSystem.self, on: .update)
        app.addSystem(GardenVisibilityStatsSystem.self, on: .update)
        if let stats = app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DVisibilityStatistics.self) {
            app.insertResource(stats)
        }
        app.addSystem(GardenPresentationSystem.self, on: .postUpdate)
        app.addSystem(GardenCameraSystem.self, on: .postUpdate)
        #if os(macOS)
            installCapture(in: app)
            if ProcessInfo.processInfo.arguments.contains("--measure-gpu"), let render = app.getSubworldBuilder(by: .renderWorld) {
                render.insertResource(Render3DPerformanceMetrics(synchronizesPasses: true))
            }
        #endif
    }
}

struct GardenPlayer: Component {
    var elapsed: Float = 0
    var jumpHeld = false
    var resetHeld = false
    var locomotion = "Idle"
    var facingYaw: Float = .pi
    var wasAirborne = false
    var landingTime: Float = 0
    var sawJump = false
    var sawFall = false
    var sawLand = false
    var proofStage = 0
    var proofMaximumHeight: Float = 0
}

struct GardenCamera: Component {
    var yaw: Float = 0.45
    var pitch: Float = 0.36
    var distance: Float = 6.6
    var actualDistance: Float = 6.6
    var focus = Vector3.zero
    var initialized = false
    var isOccluded = false
    var verifiedCollision = false
    var lastMouse = Point.zero
    var dragging = false
}

@System
@MainActor
func StartupGarden(_ context: WorldUpdateContext) async {
    do { try await makeGarden(in: context.world) } catch { gardenLog("[SkeletalGarden] startup failed: \(error)") }
}

@MainActor
private func makeGarden(in world: World) async throws {
    let backend = unsafe RenderEngine.shared.type
    if ProcessInfo.processInfo.arguments.contains("--webgpu"), backend != .webgpu {
        throw AssetError.message("WebGPU backend was requested but is not linked in this build")
    }
    gardenLog("[SkeletalGarden] backend=\(backend)")
    let device = unsafe RenderEngine.shared.renderDevice
    guard let model = (try await AssetsManager.load(ModelAsset3D.self, at: "Assets/GardenRobot.glb", from: gardenBundle)).asset else {
        throw AssetError.message("GardenRobot could not be loaded")
    }
    let player = model.instantiate(in: world)
    player.components[GardenPlayer.self] = GardenPlayer()
    player.components[CharacterController3DComponent.self] = CharacterController3DComponent(radius: 0.4, height: 2.15)
    player.components[Transform.self] = Transform(rotation: Quat(axis: .up, angle: .pi), scale: [0.5, 0.5, 0.5], position: [-0.7, 0, 0])
    if var animation = player.components[ModelAnimation3DComponent.self] {
        try animation.player.play("Idle", transitionDuration: 0)
        player.components[ModelAnimation3DComponent.self] = animation
    }
    if ProcessInfo.processInfo.arguments.contains("--controller-proof"), var transform = player.components[Transform.self] {
        transform.position = [-0.7, 0, -0.8]
        player.components[Transform.self] = transform
    }
    let reference = model.instantiate(in: world)
    reference.components[Transform.self] = Transform(rotation: Quat(axis: .up, angle: .pi), scale: [0.38, 0.38, 0.38], position: [1.5, 0, 1.8])
    if var animation = reference.components[ModelAnimation3DComponent.self] {
        try animation.player.play("Walk", transitionDuration: 0)
        animation.player.speed = 0.65
        if ProcessInfo.processInfo.arguments.contains("--render-proof") {
            animation.player.seek(to: 0.15)
            animation.player.isPlaying = false
        }
        reference.components[ModelAnimation3DComponent.self] = animation
    }
    let props: [(String, Vector3, Float)] = [
        ("Courtyard", .zero, 1), ("Crate", [-2.3, 0, -0.8], 1), ("Crate", [2.4, 0, -1.5], 0.8),
        ("Bench", [-2.8, 0, 2.5], 1), ("Plant", [-3.2, 0, -2.2], 1.2), ("Plant", [2.8, 0, 2.4], 1.1),
        ("Pedestal", [3.1, 0, 0.5], 1), ("Lantern", [3.1, 1, 0.5], 1),
    ]
    for (name, position, scale) in props {
        guard let prop = (try await AssetsManager.load(ModelAsset3D.self, at: "Assets/\(name).glb", from: gardenBundle)).asset else {
            throw AssetError.message("Missing garden prop \(name)")
        }
        let root = prop.instantiate(in: world)
        root.components[Transform.self] = Transform(scale: [scale, scale, scale], position: position)
    }
    let chrome = PBRMaterial()
    chrome.metallicFactor = 1; chrome.roughnessFactor = 0.12
    chrome.baseColorFactor = [0.85, 0.9, 0.95, 1]
    world.spawn("IBL Chrome Sphere") {
        Mesh3DComponent(mesh: Mesh.generateSphere(radius: 0.35, renderDevice: device), materials: [chrome])
        Transform(position: [2.3, 0.35, -0.15])
    }
    let lod1 = try await AssetsManager.load(ModelAsset3D.self, at: "Assets/GardenRobotLOD1.glb", from: gardenBundle)
    let lod2 = try await AssetsManager.load(ModelAsset3D.self, at: "Assets/GardenRobotLOD2.glb", from: gardenBundle)
    let characterLODs = [lod1.asset, lod2.asset].compactMap { $0 }
    if !ProcessInfo.processInfo.arguments.contains("--no-character-lod") {
        installGardenCharacterLOD(root: player, model: model, alternatives: characterLODs, world: world)
        installGardenCharacterLOD(root: reference, model: model, alternatives: characterLODs, world: world)
    }
    if ProcessInfo.processInfo.arguments.contains("--crowd") { try makeGardenCrowd(model: model, alternatives: characterLODs, world: world) }
    makeGardenCollisions(in: world)
    try await makeGardenLandscape(in: world, device: device)
    let ibl = try await AssetsManager.load(ImageBasedLighting3D.self, at: "Assets/Studio.ibl", from: gardenBundle)
    let arguments = ProcessInfo.processInfo.arguments
    let noIBL = arguments.contains("--no-ibl")
    let baseline = arguments.contains("--render-baseline")
    world.spawn("Sun") {
        DirectionalLightComponent(
            radiance: [1, 0.88, 0.7],
            intensity: GardenLightingMode.usesLocalLights(arguments: arguments) ? 0.18 : 2.5,
            shadowDistance: 60,
            shadowBias: 0.002,
            shadowSlopeBias: 0.006
        )
        Transform(rotation: Quat(axis: .right, angle: 0.9))
    }
    addGardenLocalLighting(in: world)
    var camera = Camera()
    if arguments.contains("--temporal") { camera.temporalUpscaling = .init(renderScale: 0.75) }
    camera.backgroundColor = Color(red: 0.12, green: 0.2, blue: 0.3)
    let cameraEntity = world.spawn("Camera", bundle: Camera3D(camera: camera, environment: Environment3D(
        screenSpaceReflection: ScreenSpaceReflection(isEnabled: false),
        imageBasedLighting: noIBL ? nil : ImageBasedLightingSettings(asset: ibl, intensity: 0.5),
        shadows: ShadowSettings3D(isEnabled: !arguments.contains("--no-shadows"), cascadeCount: baseline || arguments.contains("--single-shadows") ? 1 : 3),
        ambientOcclusion: ScreenSpaceAO3D(isEnabled: !baseline && !arguments.contains("--no-ao")),
        antiAliasing: baseline || arguments.contains("--no-aa") ? .none : .fxaa,
        meshVisibility: MeshVisibilitySettings3D(
            frustumCulling: !arguments.contains("--no-culling"),
            lod: !arguments.contains("--no-lod"),
            distanceCulling: !arguments.contains("--no-distance-culling"),
            gpuOcclusion: arguments.contains("--gpu-visibility")
        )
    )))
    if var environment = cameraEntity.components[Environment3D.self] {
        environment.localShadows.isEnabled = !arguments.contains("--no-local-shadows")
        if arguments.contains("--local-shadow-budget") { environment.localShadows.maximumLights = 1 }
        cameraEntity.components[Environment3D.self] = environment
    }
    cameraEntity.components[GardenCamera.self] = GardenCamera()
    if arguments.contains("--temporal-multi") {
        let texture = RenderTexture(size: [480, 320], scaleFactor: 1, format: .bgra8)
        var second = Camera(renderTarget: texture)
        second.temporalUpscaling = .init(renderScale: 0.5)
        let other = world.spawn("Temporal Texture Camera", bundle: Camera3D(camera: second))
        other.components[GardenCamera.self] = GardenCamera(yaw: -0.5, distance: 8)
    }
    gardenLog("[SkeletalGarden] loaded \(model.skins.count) skin, \(model.skins.first?.joints.count ?? 0) joints; clips=\(model.animationClips.map(\.name))")
}

func gardenLog(_ message: String) {
    #if os(Android)
    AndroidRuntime.log(message)
    #else
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
    #endif
}
