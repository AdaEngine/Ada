@_spi(AdaEngine) import AdaEngine
import Foundation

@main
struct GardenRobotApp: App {
    var body: some AppScene {
        WindowGroup(content: { GardenRobotView() }, assetBundle: .module)
            .windowTitle("GardenRobot Locomotion")
    }
}

@MainActor
private struct GardenRobotView: View {
    @State private var demo = GardenRobotDemo()

    var body: some View {
        SceneView(useSceneCameras: true, make: { Self.makeScene(in: $0) }, updateContent: demo.update) {
            Text("Loading GardenRobot…")
                .foregroundColor(.white)
        }
        .onPrepareFramePresentation { demo.preparePresentation() }
    }

    private static func makeScene(in app: AppWorlds) {
        app.addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(EventsPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(AssetsPlugin(assetBundle: .module))
            .addPlugin(VisibilityPlugin())
            .addPlugin(ScenePlugin())
            .addPlugin(Core3DPlugin())
            .addPlugin(Physics3DPlugin())
            .addPlugin(UpscalePlugin())

        app.main.spawn("GardenRobot") {
            Transform(scale: [0.55, 0.55, 0.55], position: [0, 0.005, 0])
            Model3DSource(source: "@res://GardenRobot.glb", animation: "Idle", autoplay: true)
            CharacterController3DComponent()
            CharacterLocomotion3DComponent()
        }
        app.main.spawn("Floor") {
            Transform(position: [0, -0.5, 0])
            PhysicsBody3DComponent(shapes: [.generateBox(width: 40, height: 1, depth: 40)], mode: .static)
        }
        var camera = Camera()
        camera.projection = .perspective(PerspectiveProjection())
        let cameraEntity = app.main.spawn("Camera") {
            camera
            GardenRobotDemo.followCamera(at: .zero)
        }
        SceneRuntimeBootstrap.prepareCamera(on: cameraEntity, in: app.main)
        app.main.spawn("Light") {
            DirectionalLightComponent(intensity: 4, castShadows: false)
            Transform(rotation: .euler([0.7, -0.6, 0]))
        }
    }
}

@MainActor
private final class GardenRobotDemo {
    private var phase: CharacterLocomotion3DComponent.Phase?
    private var presentedPhase: CharacterLocomotion3DComponent.Phase?
    private var elapsed: Float = 0
    private var cycle = 0
    private var jumped = false

    func update(world: World, delta: Float) {
        guard let robot = world.getEntityByName("GardenRobot") else {
            return
        }
        phase = robot.components[CharacterLocomotion3DComponent.self]?.activeState
        guard presentedPhase != nil else {
            return
        }

        elapsed += min(max(delta, 0), 0.05)
        if elapsed >= 6 {
            elapsed = 0
            jumped = false
            cycle += 1
        }
        let speed: Float
        switch elapsed {
        case 1.2..<2.5: speed = 1.65
        case 2.5..<4.65: speed = 3.3
        default: speed = 0
        }
        let direction: Float = cycle.isMultiple(of: 2) ? 1 : -1
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [speed * direction, 0, 0]
        if elapsed > 3.5, !jumped {
            robot.components[CharacterController3DComponent.self]?.jumpRequested = true
            jumped = true
        }
        if let position = robot.components[Transform.self]?.position {
            world.getEntityByName("Camera")?.components[Transform.self] = Self.followCamera(at: position)
        }
    }

    func preparePresentation() -> @MainActor () -> Void {
        let phase = self.phase
        return { [weak self] in
            guard let self, let phase, presentedPhase != phase else {
                return
            }
            presentedPhase = phase
            print("GardenRobot phase: \(phase.rawValue)")
        }
    }

    static func followCamera(at position: Vector3) -> Transform {
        Transform(position: position + Vector3(0, 0.75, -3.6))
    }
}
