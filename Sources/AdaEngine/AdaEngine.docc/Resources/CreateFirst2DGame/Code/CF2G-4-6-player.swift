import AdaEngine

struct FirstScene: Plugin {
    func setup(in _: AppWorlds) {
        /** Collapsed code */
    }
}

@Component
struct PlayerComponent {}

@System
func PlayerMovement(
    _ playerTransform: FIlterQuery<Ref<Transform>, With<PlayerComponent>>,
    _ speed: Local<Float> = 3.0,
    _ deltaTime: Res<DeltaTime>,
    _ input: Res<Input>
) {
    playerTransform.forEach { transform in
        if input.wrappedValue.isKeyPressed(.w) {
            transform.position.y += speed.wrappedValue * deltaTime.wrappedValue.deltaTime
        }
    }
}
