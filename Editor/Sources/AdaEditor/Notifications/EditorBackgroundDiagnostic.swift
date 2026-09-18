#if DEBUG && os(iOS)
    import Foundation

    /// Explicit diagnostic workload, exposed only when ADA_EDITOR_BACKGROUND_TEST=1.
    @MainActor
    final class EditorBackgroundDiagnostic {
        static let shared = EditorBackgroundDiagnostic()
        private var worker: Task<Void, Never>?

        func start() {
            guard worker == nil, #available(iOS 26.0, *) else {
                return
            }
            let coordinator = EditorNotificationCenter.shared.activities
            let id = coordinator.begin(
                .init(
                    source: .test,
                    title: "Background diagnostic",
                    detail: "Writing verification records",
                    completedUnits: 0,
                    totalUnits: 120
                ),
                cancel: { [weak self] in self?.worker?.cancel() }
            )
            EditorContinuedProcessing.shared.request(for: id, coordinator: coordinator)
            worker = Task {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("background-check-\(id).data")
                defer {
                    try? FileManager.default.removeItem(at: url)
                    worker = nil
                }
                do {
                    for unit in 1...120 {
                        try Task.checkCancellation()
                        let record = Data(repeating: UInt8(unit), count: 64 * 1024)
                        try record.write(to: url, options: .atomic)
                        guard try Data(contentsOf: url) == record else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        coordinator.update(id, detail: "Verified record \(unit) of 120", completed: Int64(unit), total: 120)
                        // Pacing makes foreground/background transitions observable with a small disk footprint.
                        try await Task.sleep(for: .seconds(1))
                    }
                    coordinator.finish(id, state: .completed)
                } catch {
                    coordinator.finish(id, state: error is CancellationError ? .cancelled : .failed, detail: error.localizedDescription)
                }
            }
        }
    }
#endif
