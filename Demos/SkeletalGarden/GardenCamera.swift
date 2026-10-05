import AdaEngine
import Foundation

@PlainSystem(dependencies: [.after(GardenPresentationSystem.self), .before(TransformSystem.self)])
struct GardenCameraSystem {
    @Query<GardenPlayer, Transform> private var players
    @Query<Ref<GardenCamera>, Ref<Transform>> private var cameras
    @ResMut<Physics3DWorldHolder> private var physics
    @Res<Input> private var input
    @Res<DeltaTime> private var time
    @Local private var proofFrame = 0
    private let temporalMotion = ProcessInfo.processInfo.arguments.contains("--temporal-motion")
    private let overview = ProcessInfo.processInfo.arguments.contains("--overview-proof")
    private let controllerProof = ProcessInfo.processInfo.arguments.contains("--controller-proof")

    init(world _: World) {}

    @MainActor
    func update(context _: UpdateContext) {
        proofFrame += 1
        var focus = Vector3(0, 1.15, 0)
        var elapsed: Float = 0
        players.forEach { player, transform in
            focus = transform.position + [0, 1.15, 0]
            elapsed = player.elapsed
        }
        let dt = time.deltaTime.isFinite ? min(max(time.deltaTime, 0), 0.1) : 0
        cameras.forEach { orbit, transform in
            let mouse = input.getMousePosition()
            let dragging = input.isMouseButtonPressed(.left)
            if dragging, orbit.dragging {
                orbit.yaw -= (mouse.x - orbit.lastMouse.x) * 0.008
                orbit.pitch = min(max(orbit.pitch + (mouse.y - orbit.lastMouse.y) * 0.006, 0.08), 1.1)
            }
            orbit.lastMouse = mouse
            orbit.dragging = dragging
            if input.isKeyPressed(.q) { orbit.distance = max(3.2, orbit.distance - dt * 5) }
            if input.isKeyPressed(.e) { orbit.distance = min(12, orbit.distance + dt * 5) }
            if temporalMotion { orbit.yaw = 0.45 + Float(proofFrame) * 0.004 }
            if controllerProof, elapsed > 6 { orbit.yaw = .pi }
            if !orbit.initialized {
                orbit.focus = focus
                orbit.initialized = true
            }
            orbit.focus += (focus - orbit.focus) * Float(1 - exp(-Double(dt) * 12))
            var eye: Vector3
            var target = orbit.focus
            if overview {
                eye = [25, 30, -31]
                target = [0, -2, 1]
            } else {
                let offset = Vector3(Math.sin(orbit.yaw) * Math.cos(orbit.pitch), Math.sin(orbit.pitch), -Math.cos(orbit.yaw) * Math.cos(orbit.pitch)) * orbit.distance
                let travel = orbit.focus + offset - focus
                let fraction = physics.world.sphereCastFraction(from: focus, to: focus + travel, radius: 0.24)
                let allowed = max(0, travel.length * fraction - 0.08)
                orbit.isOccluded = fraction < 0.99
                if allowed < orbit.actualDistance {
                    orbit.actualDistance = allowed
                } else { orbit.actualDistance += (allowed - orbit.actualDistance) * Float(1 - exp(-Double(dt) * 5)) }
                eye = focus + travel.normalized * orbit.actualDistance
                if temporalMotion { orbit.yaw = 0.45 + Float(proofFrame) * 0.004 }
            if controllerProof, elapsed > 6.8, !orbit.verifiedCollision {
                    let passed = orbit.isOccluded && orbit.actualDistance < orbit.distance - 1
                    gardenLog("[SkeletalGarden] controller camera-sweep \(passed ? "PASS" : "FAIL") distance=\(orbit.actualDistance)")
                    orbit.verifiedCollision = true
                }
            }
            var forward = target - eye
            if forward.length < 0.01 { forward = [0, 0, 1] }
            forward = forward.normalized
            let right = Vector3.up.cross(forward).normalized
            let up = forward.cross(right)
            transform.wrappedValue = Transform(matrix: Transform3D(Vector4(right, 0), Vector4(up, 0), Vector4(forward, 0), Vector4(eye, 1)))
        }
    }
}
