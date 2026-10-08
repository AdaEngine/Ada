import AdaEngine

@MainActor
struct EventListenerPlugin: Plugin {
    @Local var disposeBag: Set<AnyCancellable> = []

    func setup(in app: borrowing AppWorlds) {
        app.main
            .subscribe(to: SceneEvents.OnReady.self) { event in
                Task { @MainActor in
                    event.scene.world.physicsWorld2D?.gravity = .zero
                }
            }
            .store(in: &self.disposeBag)
    }
}
