import AdaEngine

@main
struct SkeletalGarden: App {
    var body: some AppScene {
        DefaultAppWindow(assetBundle: .module)
            .addPlugins(GardenPlugin())
            .window(with: UIWindow.Configuration(
                title: "AdaEngine · Skeletal Garden · WASD / Shift / drag to orbit",
                frame: Rect(x: 120, y: 100, width: 1100, height: 760)
            ))
    }
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

@System
@MainActor
func StartupGarden(_ context: WorldUpdateContext) {
    do { try makeGarden(in: context.world, assetBundle: .module) } catch { print("[SkeletalGarden] startup failed: \(error)") }
}

@PlainSystem
struct UpdateGardenSystem {
    @Query<GardenPlayer, Ref<Transform>, Ref<ModelAnimation3DComponent>> private var players
    @Query<Ref<GardenPlayer>> private var playerTimers
    @Query<Ref<GardenCamera>, Ref<Transform>> private var cameras
    @Res<Input> private var input
    @Res<DeltaTime> private var time
    private let autoplay = ProcessInfo.processInfo.arguments.contains("--autoplay")
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
                do { try animation.player.play(clip) } catch { print("[SkeletalGarden] \(error)") }
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
            let mouse = input.getMousePosition()
            let dragging = input.isMouseButtonPressed(.left)
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
