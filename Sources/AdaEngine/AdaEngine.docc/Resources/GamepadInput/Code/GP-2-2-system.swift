import AdaEngine

@PlainSystem
struct GamepadInputSystem {

    @FilterQuery<Ref<Transform>, With<PlayerComponent>>
    private var playerQuery

    @Res<Input>
    private var input

    @Res<DeltaTime>
    private var deltaTime

    init(world _: World) {}

    func update(context _: UpdateContext) {
        let gamepads = input.getConnectedGamepads()

        if gamepads.isEmpty {
            return
        }

        for gamepad in gamepads {
            // Handle per-gamepad input
        }
    }
}
