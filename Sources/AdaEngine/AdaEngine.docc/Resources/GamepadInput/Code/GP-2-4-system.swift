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
            let leftStickX = gamepad.getAxisValue(.leftStickX)
            let leftStickY = gamepad.getAxisValue(.leftStickY)
            let deadzone: Float = 0.1

            if abs(leftStickX) > deadzone || abs(leftStickY) > deadzone {
                playerQuery.forEach { transform in
                    let speed: Float = 2.0
                    transform.position.x += leftStickX * Float(deltaTime.deltaTime) * speed
                    transform.position.y -= leftStickY * Float(deltaTime.deltaTime) * speed
                }
            }
        }
    }
}
