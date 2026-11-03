import AdaEngine
import Foundation

enum SponzaWarmupError: Error, CustomStringConvertible {
    case alreadyWaiting
    case timedOut(String)

    var description: String {
        switch self {
        case .alreadyWaiting: "Прогрев уже ожидает кадры"
        case .timedOut(let stage): "Не получены готовые кадры прогрева: \(stage)"
        }
    }
}

/// A demo-local barrier driven by actual SceneView publications, not elapsed warmup time.
@MainActor
final class SponzaWarmupFrames {
    private struct Waiter {
        let id: UUID
        let target: Int
        let condition: @MainActor () -> Bool
        let continuation: CheckedContinuation<Void, any Error>
        let deadline: Task<Void, Never>
    }
    private var publications = 0
    private var waiter: Waiter?

    func didPublish() {
        publications += 1
        guard let waiter, publications >= waiter.target, waiter.condition() else { return }
        finish(waiter.id)
    }

    func wait(stage: String, frames: Int = 6, timeout: Duration = .seconds(60),
              condition: @escaping @MainActor () -> Bool = { true }) async throws {
        guard waiter == nil else { throw SponzaWarmupError.alreadyWaiting }
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, error: SponzaWarmupError.timedOut(stage))
                }
                waiter = Waiter(id: id, target: publications + frames, condition: condition, continuation: continuation, deadline: deadline)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, error: CancellationError()) }
        }
    }

    private func finish(_ id: UUID, error: (any Error)? = nil) {
        guard let pending = waiter, pending.id == id else { return }
        waiter = nil
        pending.deadline.cancel()
        if let error { pending.continuation.resume(throwing: error) } else { pending.continuation.resume() }
    }
}

extension SponzaSession {
    /// Render both depth-format pipeline variants while controls remain in the loading state.
    func warmupRaster(app: AppWorlds) async throws {
        let selectedPreset = preset
        let selectedDLSS = dlssEnabled
        let selectedMap = meshletMapEnabled
        let selectedMeshlets = meshletMode
        let selectedLODError = meshletLODError
        let selectedFlight = flyingLightEnabled
        let selectedLights = lightCount
        @MainActor func restoreSelection() {
            dlssEnabled = selectedDLSS
            meshletMapEnabled = selectedMap
            meshletMode = selectedMeshlets
            meshletLODError = selectedLODError
            flyingLightEnabled = selectedFlight
            apply(preset: selectedPreset, lights: selectedLights)
        }
        do {
            let variants = dlssAvailable ? [false, true] : [false]
            for temporal in variants {
                try Task.checkCancellation()
                let stage = temporal ? "растр · DLSS вкл." : "растр · DLSS выкл."
                status = "Прогреваем \(stage)…"
                try await app.withWorldAccess {
                    dlssEnabled = temporal
                    meshletMapEnabled = false
                    // Prime the exact leaf stream as well as the selected hierarchy below. Otherwise
                    // turning LOD off first uploads Ivy's large v1 stream during camera movement.
                    meshletMode = selectedMeshlets == .gpu ? .gpu : .disabled
                    meshletLODError = 0
                    flyingLightEnabled = false
                    apply(preset: .fullRaster, lights: selectedLights)
                }
                // Six publications exceed the three in-flight slots. The DLSS stage additionally
                // requires encoded temporal frames; an empty/fallback-only image cannot prove warmup.
                try await warmupFrames.wait(stage: stage) { [weak self] in
                    guard let snapshots = self?.temporalStatistics?.snapshots else { return true }
                    return temporal ? snapshots.values.contains { $0.encodedFrames >= 3 && $0.fallbackFrames == 0 } : snapshots.isEmpty
                }
                FileHandle.standardOutput.write(Data("SPONZA_WARMUP_READY \(temporal ? "temporal" : "native")\n".utf8))
            }
            status = "Готовим выбранный режим…"
            try await app.withWorldAccess { restoreSelection() }
            try await warmupFrames.wait(stage: "выбранный режим")
        } catch {
            try? await app.withWorldAccess { restoreSelection() }
            throw error
        }
    }
}
