import AdaECS
import Foundation

/// Saves dirty resident and hidden regions to the loaded source's native manifest.
/// Capture after a completed edit. Removal cancels an unpublished save; a committed save still reports success.
public struct Terrain3DSave: Component, Sendable {
    public let id: UUID
    public let expectedRevision: UInt64
    public let maximumStagedBytes: Int
    let storage: TerrainHeightStorage
    let onProgress: (@Sendable (Int, Int) async -> Void)?
    let receipt = TerrainSourceSaveReceipt()

    /// Remove the ECS command at a world mutation boundary before consulting this flag
    /// for cleanup, so a not-yet-started request cannot subsequently be admitted.
    public var hasStartedWriting: Bool { receipt.hasStarted }
    /// Actual filesystem completion, independent of later ECS acknowledgment. A save may
    /// have committed despite cancellation; wait for this receipt before deleting its destination.
    public var completion: Terrain3DSaveStatus? { receipt.completion }

    public init(
        storage: TerrainHeightStorage,
        maximumStagedBytes: Int = 128 * 1_024 * 1_024,
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) {
        id = UUID()
        self.storage = storage
        expectedRevision = storage.revision
        self.maximumStagedBytes = maximumStagedBytes
        self.onProgress = onProgress
    }
}

public enum TerrainSavePhase: Equatable, Sendable { case pending, saved, failed, cancelled }

/// Transient save completion. Saving the scene itself persists only its terrain URI.
public struct Terrain3DSaveStatus: Component, Sendable {
    public let id: UUID
    public let phase: TerrainSavePhase
    public let savedRevision: UInt64?
    public let error: String?
}

enum TerrainSourceSaveError: LocalizedError {
    case sourceUnavailable, wrongSurface, staleRevision, busy
    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "Terrain saving requires a loaded source with published settings"
        case .wrongSurface: "Terrain save belongs to a different surface"
        case .staleRevision: "Terrain changed after the save request was captured"
        case .busy: "Complete the pending terrain operation before saving"
        }
    }
}

extension Terrain3DSourceSystem {
    static func finishSave(_ request: Terrain3DSave, phase: TerrainSavePhase, revision: UInt64? = nil, error: String? = nil, owner: Entity) {
        if owner.components[Terrain3DSave.self]?.id == request.id { owner.components.remove(Terrain3DSave.self) }
        let status = Terrain3DSaveStatus(id: request.id, phase: phase, savedRevision: revision, error: error)
        request.receipt.rejectBeforeStart(status)
        owner.components[Terrain3DSaveStatus.self] = status
    }

    /// True defers this source's normal geometry processing until its save finishes.
    static func routeSave(
        entity: Entity,
        source: Terrain3DSource,
        state: TerrainSourceState?,
        request: Terrain3DSave?,
        changed: Bool,
        geometryBusy: Bool,
        queue: TerrainSourceSaveQueue,
        commands: WorldCommandQueue
    ) -> Bool {
        let id = entity.id
        if let active = state?.saveJob, active.request.id != request?.id || changed {
            let cancelling = active.request.id != request?.id || active.key != TerrainSourceKey(source)
            queue.retire(active, owner: id, cancelling: cancelling)
            commands.push { world in
                guard let owner = world.getEntityByID(id) else {
                    return
                }
                if var current = owner.components[TerrainSourceState.self], current.saveJob === active {
                    current.saveJob = nil
                    owner.components[TerrainSourceState.self] = current
                }
                if cancelling, owner.components[Terrain3DSave.self]?.id == active.request.id { owner.components.remove(Terrain3DSave.self) }
            }
            return false
        }
        // Detached snapshots retain their command for explicit cancellation while normal
        // residency and editing proceed; this is the same operation, never a second admission.
        if let request, state?.saveJob == nil, queue.contains(request.id) {
            return false
        }
        guard state?.saveJob != nil || request != nil else {
            return false
        }
        guard state?.saveJob != nil || (!geometryBusy && saveIsCoherent(source, state: state, owner: entity)) else {
            queue.stopWaiting(id)
            if let request {
                commands.push { world in
                    guard let owner = world.getEntityByID(id), owner.components[Terrain3DSave.self]?.id == request.id else {
                        return
                    }
                    finishSave(request, phase: .failed, error: TerrainSourceSaveError.busy.localizedDescription, owner: owner)
                }
            }
            return false
        }
        if state?.saveJob != nil || queue.admit(id) {
            commands.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == source else {
                    queue.releaseReservation(id)
                    return
                }
                advanceSave(owner.components[Terrain3DSave.self], source: source, owner: owner, queue: queue)
            }
        } else if let request {
            if changed {
                // No immutable snapshot exists yet. Let residency/physics catch up instead
                // of freezing this source behind another user's paused filesystem callback.
                queue.stopWaiting(id)
                commands.push { world in
                    guard let owner = world.getEntityByID(id), owner.components[Terrain3DSave.self]?.id == request.id else {
                        return
                    }
                    finishSave(request, phase: .failed, error: TerrainSourceSaveError.busy.localizedDescription, owner: owner)
                }
                return false
            }
            commands.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3DSave.self]?.id == request.id else {
                    return
                }
                owner.components[Terrain3DSaveStatus.self] = .init(id: request.id, phase: .pending, savedRevision: nil, error: nil)
            }
        }
        return true
    }

    static func saveIsCoherent(_ source: Terrain3DSource, state: TerrainSourceState?, owner: Entity) -> Bool {
        guard let state, let storage = state.storage else {
            return false
        }
        return state.key == TerrainSourceKey(source) && state.revision == storage.revision
            && state.matrix == worldMatrix(owner) && hasPublishedHeightEditConfiguration(state, source: source)
            && owner.components[Terrain3DSourceStatus.self]?.isReady == true
            && owner.components[Terrain3DSourceStatus.self]?.isPreparing != true
            && owner.components[Terrain3DHeightEdit.self] == nil
    }

    /// Returns false only when a concurrent low-level write invalidated acknowledgment's export.
    static func acknowledgeSave(_ job: TerrainSourceSaveJob, cache: TerrainRegionCache, owner: Entity) -> Bool {
        if var state = owner.components[TerrainSourceState.self], state.storage === job.snapshot.storage {
            guard let residency = state.residency else {
                return false
            }
            do { state.residency = try residency.acknowledging(job.snapshot, cache: cache) } catch {
                return false
            }
            state.focus = nil
            if state.saveJob === job { state.saveJob = nil }
            owner.components[TerrainSourceState.self] = state
            if let surface = owner.components[Terrain3DSourceSurface.self], surface.storage === job.snapshot.storage {
                owner.components[Terrain3DSourceSurface.self] = .init(storage: surface.storage, queries: surface.queries, manifest: cache.manifest)
            }
        }
        if owner.components[Terrain3DSaveStatus.self]?.id == job.request.id || owner.components[Terrain3DSave.self]?.id == job.request.id {
            finishSave(job.request, phase: .saved, revision: job.snapshot.revision, owner: owner)
        }
        return true
    }

    static func completeRetiredSave(_ job: TerrainSourceSaveJob, outcome: TerrainSourceSaveOutcome, owner: Entity) -> Bool {
        guard owner.components[Terrain3DSource.self] != nil else {
            return true
        }
        switch outcome {
        case let .saved(cache): return acknowledgeSave(job, cache: cache, owner: owner)
        case let .failed(message):
            if owner.components[Terrain3DSaveStatus.self]?.id == job.request.id || owner.components[Terrain3DSave.self]?.id == job.request.id {
                finishSave(job.request, phase: .failed, error: message, owner: owner)
            }
        case .cancelled:
            if owner.components[Terrain3DSaveStatus.self]?.id == job.request.id || owner.components[Terrain3DSave.self]?.id == job.request.id {
                finishSave(job.request, phase: .cancelled, owner: owner)
            }
        }
        return true
    }

    static func advanceSave(_ request: Terrain3DSave?, source: Terrain3DSource, owner: Entity, queue: TerrainSourceSaveQueue) {
        defer { queue.releaseReservation(owner.id) }
        guard var state = owner.components[TerrainSourceState.self] else {
            if let request { finishSave(request, phase: .failed, error: TerrainSourceSaveError.sourceUnavailable.localizedDescription, owner: owner) }
            return
        }
        if let job = state.saveJob {
            if request?.id != job.request.id { job.cancel() }
            guard let outcome = job.result else {
                return
            }
            switch outcome {
            case let .saved(cache):
                if acknowledgeSave(job, cache: cache, owner: owner) { queue.complete(job.request.id) }
                return
            case let .failed(message): finishSave(job.request, phase: .failed, error: message, owner: owner)
            case .cancelled: finishSave(job.request, phase: .cancelled, owner: owner)
            }
            state.saveJob = nil
            owner.components[TerrainSourceState.self] = state
            queue.complete(job.request.id)
            return
        }
        guard let request else {
            return
        }
        do {
            guard let storage = state.storage, let residency = state.residency else { throw TerrainSourceSaveError.sourceUnavailable }
            guard storage === request.storage else { throw TerrainSourceSaveError.wrongSurface }
            guard storage.revision == request.expectedRevision else { throw TerrainSourceSaveError.staleRevision }
            guard saveIsCoherent(source, state: state, owner: owner) else { throw TerrainSourceSaveError.busy }
            let snapshot = try residency.saveSnapshot(request)
            let job = TerrainSourceSaveJob(request: request, key: TerrainSourceKey(source), snapshot: snapshot, cache: residency.cache)
            queue.track(job, owner: owner.id)
            // Every captured canonical resource is already admitted. Preserve it when a
            // concurrent camera/physics request builds the next working set.
            state.residency = residency.pinning(queue.pinnedRegions(owner: owner.id, storage: storage))
            state.saveJob = job
            owner.components[TerrainSourceState.self] = state
            owner.components[Terrain3DSaveStatus.self] = .init(id: request.id, phase: .pending, savedRevision: nil, error: nil)
        } catch { finishSave(request, phase: .failed, error: error.localizedDescription, owner: owner) }
    }
}
