import AdaECS
import Foundation
import Synchronization

/// Owns at most two filesystem snapshots, including cancelled tasks awaiting their final receipts.
/// The command queue and source update share this synchronized owner; workers never access ECS.
final class TerrainSourceSaveQueue: Sendable {
    struct Entry: Sendable {
        let owner: Entity.ID
        let job: TerrainSourceSaveJob
        var retired: Bool
    }

    private struct State {
        var jobs: [UUID: Entry] = [:]
        var waiting: [Entity.ID] = []
        var waitingSet: Set<Entity.ID> = []
        var reserved: Set<Entity.ID> = []
    }

    private let state = Mutex(State())

    func reconcile(sources: [Entity.ID: TerrainSourceKey], requests: [Entity.ID: UUID]) {
        let cancel = state.withLock { value -> [TerrainSourceSaveJob] in
            value.waiting.removeAll { sources[$0] == nil || requests[$0] == nil }
            value.waitingSet = Set(value.waiting)
            value.reserved.formIntersection(sources.keys)
            var cancel: [TerrainSourceSaveJob] = []
            for id in Array(value.jobs.keys) {
                guard let entry = value.jobs[id],
                    sources[entry.owner] != entry.job.key || requests[entry.owner] != entry.job.request.id
                else { continue }
                value.jobs[id]?.retired = true
                cancel.append(entry.job)
            }
            return cancel
        }
        for job in cancel { job.cancel() }
    }

    var hasJobs: Bool { state.withLock { !$0.jobs.isEmpty || !$0.reserved.isEmpty } }

    func drain(states: [Entity.ID: TerrainSourceState], busy: Set<Entity.ID>, commands: WorldCommandQueue) -> Set<Entity.ID> {
        var acknowledging: Set<Entity.ID> = []
        for entry in retired {
            guard let outcome = entry.job.result else { continue }
            if case .saved = outcome, states[entry.owner]?.storage === entry.job.snapshot.storage {
                guard !busy.contains(entry.owner) else { continue }
                acknowledging.insert(entry.owner)
            }
            commands.push { world in
                guard let owner = world.getEntityByID(entry.owner) else {
                    self.complete(entry.job.request.id)
                    return
                }
                if Terrain3DSourceSystem.completeRetiredSave(entry.job, outcome: outcome, owner: owner) { self.complete(entry.job.request.id) }
            }
        }
        return acknowledging
    }

    func admit(_ owner: Entity.ID) -> Bool {
        state.withLock { value in
            if value.waitingSet.insert(owner).inserted { value.waiting.append(owner) }
            guard value.waiting.first == owner, value.jobs.count + value.reserved.count < 2 else {
                return false
            }
            value.waiting.removeFirst()
            value.waitingSet.remove(owner)
            value.reserved.insert(owner)
            return true
        }
    }

    func releaseReservation(_ owner: Entity.ID) { state.withLock { _ = $0.reserved.remove(owner) } }

    func track(_ job: TerrainSourceSaveJob, owner: Entity.ID) {
        state.withLock { value in
            value.reserved.remove(owner)
            value.jobs[job.request.id] = .init(owner: owner, job: job, retired: false)
        }
    }

    func stopWaiting(_ owner: Entity.ID) {
        state.withLock { value in
            value.waitingSet.remove(owner)
            value.waiting.removeAll { $0 == owner }
        }
    }

    func retire(_ job: TerrainSourceSaveJob, owner: Entity.ID, cancelling: Bool = true) {
        state.withLock { value in
            value.jobs[job.request.id] = .init(owner: owner, job: job, retired: true)
            value.waitingSet.remove(owner)
            value.waiting.removeAll { $0 == owner }
        }
        if cancelling { job.cancel() }
    }

    /// Canonical resources held by active, detached or cancelling filesystem transactions.
    func pinnedRegions(owner: Entity.ID, storage: TerrainHeightStorage?) -> Set<TerrainRegionCoordinate> {
        guard let storage else {
            return []
        }
        return state.withLock { value in
            var result: Set<TerrainRegionCoordinate> = []
            for entry in value.jobs.values where entry.owner == owner && entry.job.snapshot.storage === storage {
                result.formUnion(entry.job.snapshot.payloads.keys)
            }
            return result
        }
    }

    func contains(_ id: UUID) -> Bool { state.withLock { $0.jobs[id] != nil } }
    func complete(_ id: UUID) { state.withLock { _ = $0.jobs.removeValue(forKey: id) } }
    var retired: [Entry] { state.withLock { $0.jobs.values.filter(\.retired) } }
}
