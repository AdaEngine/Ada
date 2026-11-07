import AdaECS
import AdaTransform
import Math

/// Moves upright character capsules after each physics step, before transform propagation.
@PlainSystem(dependencies: [.after(Physics3DWritebackSystem.self)])
public struct CharacterController3DSystem {
    @FilterQuery<Ref<CharacterController3DComponent>, Ref<Transform>, Without<PhysicsBody3DComponent>> private var characters
    @ResMut<Physics3DWorldHolder> private var physics
    @Res<FixedTime?> private var time
    @Res<PhysicsSimulationGate3D?> private var gate

    public init(world _: World) {}

    @MainActor
    public func update(context _: UpdateContext) {
        guard gate?.isReady != false else {
            return
        }
        guard let time else {
            return
        }
        characters.forEach { controller, transform in
            if controller.resetMotion {
                controller.wrappedValue.horizontalVelocity = .zero
                controller.wrappedValue.verticalVelocity = 0
                controller.wrappedValue.velocity = .zero
                controller.wrappedValue.isGrounded = false
                controller.jumpRequested = false
                controller.resetMotion = false
            }
            var position = transform.position
            physics.world.moveCharacter(&controller.wrappedValue, position: &position, deltaTime: time.deltaTime)
            if position != transform.position { transform.position = position }
        }
    }
}
