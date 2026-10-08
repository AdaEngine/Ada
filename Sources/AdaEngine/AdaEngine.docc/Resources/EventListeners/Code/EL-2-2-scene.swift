import AdaEngine

@MainActor
struct EventListenerPlugin: Plugin {
    @Local var disposeBag: Set<AnyCancellable> = []

    func setup(in _: borrowing AppWorlds) {

    }
}
