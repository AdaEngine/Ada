@_spi(AdaEngine) import AdaEngine
import Foundation

/// One bounded mailbox for UI poses. World mutation always occurs between updates;
/// newer pointer samples replace older samples for the same retained source.
@MainActor
final class EditorMeshTerrainPoseQueue {
    private struct Intent {
        let pose: Transform
        let source: Entity
        let prepared: Task<Void, any Error>?
        let ticket: MeshTerrainEditTicket
    }
    private var pending: [Entity.ID: Intent] = [:]
    private var tickets: [Entity.ID: MeshTerrainEditTicket] = [:]
    private var worker: Task<Void, Never>?
    private var generation = UUID()

    @discardableResult
    func propose(_ pose: Transform, for source: Entity, application: AppWorlds, prepared: Task<Void, any Error>? = nil) -> Bool {
        tickets = tickets.filter { $0.value.isPending }
        guard tickets[source.id] != nil || tickets.count < 512 else { return false }
        tickets[source.id]?.supersede()
        let ticket = MeshTerrainEditTicket()
        tickets[source.id] = ticket
        pending[source.id] = .init(pose: pose, source: source, prepared: prepared, ticket: ticket)
        guard worker == nil else { return true }
        let generation = generation
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.worker = nil } }
            while !self.pending.isEmpty {
                do {
                    let batch = self.pending
                    self.pending.removeAll(keepingCapacity: true)
                    var accepted: [Entity.ID: Intent] = [:]
                    for (id, intent) in batch {
                        do { try await intent.prepared?.value; accepted[id] = intent }
                        catch {
                            if self.tickets[id] === intent.ticket { self.discard(id) }
                        }
                    }
                    try await application.withWorldAccess {
                        guard self.generation == generation else { throw CancellationError() }
                        for id in accepted.keys.sorted() {
                            guard let intent = accepted[id], self.tickets[id] === intent.ticket, intent.ticket.isPending else { continue }
                            guard application.main.getEntityByID(id) === intent.source else { self.discard(id); continue }
                            if intent.source.components[MeshTerrain3DBinding.self]?.enabled == true {
                                intent.source.components[MeshTerrain3DProposedPose.self] = .init(intent.pose, ticket: intent.ticket)
                            } else {
                                intent.source.components[Transform.self] = intent.pose
                                self.discard(id)
                            }
                        }
                    }
                } catch { return }
            }
        }
        return true
    }

    func discard(_ source: Entity.ID) {
        pending.removeValue(forKey: source)
        tickets.removeValue(forKey: source)?.supersede()
    }

    func cancel() {
        generation = UUID()
        pending.removeAll(keepingCapacity: false)
        for ticket in tickets.values { ticket.supersede() }
        tickets.removeAll(keepingCapacity: false)
        worker?.cancel()
        worker = nil
    }
}
