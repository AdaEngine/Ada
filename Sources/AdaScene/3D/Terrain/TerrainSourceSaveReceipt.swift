import Synchronization

/// Worker completion is retained independently of ECS frames, including retired saves.
final class TerrainSourceSaveReceipt: Sendable {
    private struct State {
        var started = false
        var completion: Terrain3DSaveStatus?
    }
    private let state = Mutex(State())

    var hasStarted: Bool { state.withLock { $0.started } }
    var completion: Terrain3DSaveStatus? { state.withLock { $0.completion } }
    func start() { state.withLock { $0.started = true } }

    func rejectBeforeStart(_ status: Terrain3DSaveStatus) {
        state.withLock { value in
            guard !value.started, value.completion == nil else {
                return
            }
            value.completion = status
        }
    }

    func complete(_ status: Terrain3DSaveStatus) {
        state.withLock { value in
            guard value.completion == nil else {
                return
            }
            value.completion = status
        }
    }
}
