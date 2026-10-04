import AdaEngine
import Foundation

@PlainSystem
struct GardenInputSystem {
    @Query<Ref<GardenPlayer>, Ref<CharacterController3DComponent>, Ref<Transform>> private var players
    @Query<GardenCamera> private var cameras
    @Res<Input> private var input
    @Res<DeltaTime> private var time
    private let autoplay = ProcessInfo.processInfo.arguments.contains("--autoplay")
    private let poseProof = ProcessInfo.processInfo.arguments.contains("--pose-proof")
    private let controllerProof = ProcessInfo.processInfo.arguments.contains("--controller-proof")

    init(world _: World) {}

    func update(context _: UpdateContext) {
        var yaw: Float = 0.45
        cameras.forEach { yaw = $0.yaw }
        let forward = Vector3(-Math.sin(yaw), 0, Math.cos(yaw))
        let right = Vector3(Math.cos(yaw), 0, Math.sin(yaw))
        players.forEach { state, controller, transform in
            // The scheduler's first wall-clock delta can include time before app startup.
            state.elapsed += time.deltaTime.isFinite ? min(max(time.deltaTime, 0), 0.1) : 0
            var direction = Vector3.zero
            if input.isKeyPressed(.w) { direction += forward }
            if input.isKeyPressed(.s) { direction -= forward }
            if input.isKeyPressed(.a) { direction -= right }
            if input.isKeyPressed(.d) { direction += right }
            let running = input.isKeyPressed(.shift) || autoplay && Int(state.elapsed / 3).isMultiple(of: 2) || controllerProof
            if autoplay { direction = [Math.cos(state.elapsed * 0.6), 0, Math.sin(state.elapsed * 0.6)] }
            var jumping = input.isKeyPressed(.space)
            if controllerProof {
                if state.elapsed >= 1, state.elapsed < 3 {
                    direction = [-1, 0, 0]
                } else if state.elapsed >= 4, state.elapsed < 6 {
                    direction = [0, 0, 1]
                } else { direction = .zero }
                jumping = state.elapsed >= 7 && state.elapsed < 7.2
            }
            if poseProof { direction = .zero; jumping = false }
            controller.desiredVelocity = direction.length > 0.01 ? direction.normalized * (running ? 2.2 : 1.1) : .zero
            if jumping, !state.jumpHeld { controller.jumpRequested = true }
            state.jumpHeld = jumping
            let resetting = input.isKeyPressed(.r)
            if transform.position.y < -8 || resetting && !state.resetHeld {
                transform.position = [-0.7, 0.1, 0]
                controller.wrappedValue = CharacterController3DComponent(radius: 0.4, height: 2.15)
            }
            state.resetHeld = resetting
        }
    }
}

@PlainSystem(dependencies: [.before(SkeletalAnimation3DSystem.self), .before(TransformSystem.self)])
struct GardenPresentationSystem {
    @Query<Ref<GardenPlayer>, CharacterController3DComponent, Ref<Transform>, Ref<ModelAnimation3DComponent>> private var players
    @Query<Ref<GardenCamera>, Ref<Transform>> private var cameras
    @Res<Input> private var input
    @Res<DeltaTime> private var time
    private let poseProof = ProcessInfo.processInfo.arguments.contains("--pose-proof")
    private let controllerProof = ProcessInfo.processInfo.arguments.contains("--controller-proof")

    init(world _: World) {}

    func update(context _: UpdateContext) {
        var focus = Vector3(0, 1, 0)
        players.forEach { state, controller, transform, animation in
            let horizontal = Vector3(controller.velocity.x, 0, controller.velocity.z)
            let speed = horizontal.length
            // Hysteresis prevents clip thrashing at low speeds and near the walk/run boundary.
            let idleThreshold: Float = state.locomotion == "Idle" ? 0.16 : 0.07
            let runThreshold: Float = state.locomotion == "Run" ? 1.4 : 1.65
            let clip = poseProof ? "Walk" : (speed < idleThreshold ? "Idle" : (speed > runThreshold ? "Run" : "Walk"))
            if clip != state.locomotion {
                do {
                    let oldName = state.locomotion
                    let oldDuration = animation.player.clipIndex.map { animation.player.clips[$0].duration } ?? 0
                    let phase = oldDuration > 0 ? animation.player.time.truncatingRemainder(dividingBy: oldDuration) / oldDuration : 0
                    let duration = animation.player.clips.first { $0.name == clip }?.duration ?? 0
                    try animation.player.play(clip, transitionDuration: 0.22, startTime: oldName != "Idle" && clip != "Idle" ? phase * duration : 0)
                    state.locomotion = clip
                } catch { gardenLog("[SkeletalGarden] \(error)") }
            }
            if clip != "Idle" {
                let referenceSpeed: Double = clip == "Run" ? 2.2 : 1.1
                animation.player.speed = poseProof ? 1 : min(max(Double(speed) / referenceSpeed, 0.25), 1.5)
            } else { animation.player.speed = 1 }
            if speed > 0.07, !poseProof {
                var turn = (Math.atan2(horizontal.x, horizontal.z) - state.facingYaw).truncatingRemainder(dividingBy: .pi * 2)
                if turn > .pi { turn -= .pi * 2 }
                if turn < -.pi { turn += .pi * 2 }
                state.facingYaw += turn * Float(1 - exp(-Double(time.deltaTime) * 12))
                transform.rotation = Quat(axis: .up, angle: state.facingYaw)
            }
            focus = transform.position + [0, 1, 0]
            if controllerProof { verifyGardenController(state: state, controller: controller, position: transform.position) }
        }
        cameras.forEach { orbit, transform in
            let mouse = input.getMousePosition()
            let dragging = input.isMouseButtonPressed(.left)
            if dragging, orbit.dragging {
                orbit.yaw -= (mouse.x - orbit.lastMouse.x) * 0.008
                orbit.pitch = min(max(orbit.pitch + (mouse.y - orbit.lastMouse.y) * 0.006, 0.1), 0.8)
            }
            orbit.lastMouse = mouse
            orbit.dragging = dragging
            let distance: Float = 4.6
            let eye = focus + Vector3(Math.sin(orbit.yaw) * distance, Math.sin(orbit.pitch) * distance + 0.5, -Math.cos(orbit.yaw) * distance)
            let forward = (focus - eye).normalized
            let right = Vector3.up.cross(forward).normalized
            let up = forward.cross(right)
            transform.wrappedValue = Transform(matrix: Transform3D(Vector4(right, 0), Vector4(up, 0), Vector4(forward, 0), Vector4(eye, 1)))
        }
    }
}

private func verifyGardenController(state: Ref<GardenPlayer>, controller: CharacterController3DComponent, position: Vector3) {
    let elapsed = state.elapsed
    if elapsed >= 7 { state.proofMaximumHeight = max(state.proofMaximumHeight, position.y) }
    if elapsed >= 2.8, state.proofStage == 0 {
        let passed = position.x > -1.5 && position.x < -1.35 && abs(controller.velocity.x) < 0.05 && controller.isGrounded && state.locomotion == "Idle"
        gardenLog("[SkeletalGarden] controller crate-stop \(passed ? "PASS" : "FAIL") position=\(position) clip=\(state.locomotion) elapsed=\(elapsed)")
        state.proofStage = passed ? 1 : -1
    }
    if elapsed >= 6.6, state.proofStage == 1 {
        let passed = position.z > 2.8 && controller.velocity.length < 0.05 && controller.isGrounded && state.locomotion == "Idle"
        gardenLog("[SkeletalGarden] controller move-and-brake \(passed ? "PASS" : "FAIL") position=\(position)")
        state.proofStage = passed ? 2 : -1
    }
    if elapsed >= 9.5, state.proofStage == 2 {
        let passed = state.proofMaximumHeight > 0.7 && abs(position.y) < 0.02 && controller.isGrounded
        gardenLog("[SkeletalGarden] controller jump-and-land \(passed ? "PASS" : "FAIL") peak=\(state.proofMaximumHeight)")
        if passed { gardenLog("[SkeletalGarden] controller verification PASS") }
        state.proofStage = passed ? 3 : -1
    }
}
