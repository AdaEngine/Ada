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
    _: FIlterQuery<Ref<Transform>, With<PlayerComponent>>,
    _: Local<Float> = 3.0
) {

}
