/// One active history restore and at most one pending restore. A new request
/// replaces the pending value and cancels the active worker before it is drained.
@MainActor
final class EditorMeshTerrainHistoryQueue {
    struct Intent {
        let apply: @MainActor () async throws -> Void
        let failed: @MainActor (String) -> Void
        let finished: @MainActor () -> Void
    }

    private var pending: Intent?
    private var active: Task<Void, any Error>?
    private var worker: Task<Void, Never>?
    var isRunning: Bool { worker != nil }

    func submit(_ intent: Intent) -> Task<Void, Never> {
        pending = intent
        active?.cancel()
        if let worker { return worker }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var latest: Intent?
            defer {
                self.worker = nil
                latest?.finished()
            }
            while let next = self.pending {
                self.pending = nil
                latest = next
                let operation = Task { @MainActor in try await next.apply() }
                self.active = operation
                do { try await operation.value }
                catch is CancellationError {}
                catch { if self.pending == nil { next.failed(error.localizedDescription) } }
                self.active = nil
            }
        }
        worker = task
        return task
    }

    func cancel() {
        pending = nil
        active?.cancel()
    }
}
