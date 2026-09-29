// A synchronous transaction publishes state immediately, then rebuilds each
// affected node once. No pending work or animation policy escapes the scope.
@MainActor
final class StateUpdateBatch {
    private(set) static var current: StateUpdateBatch?

    private struct Entry {
        weak var node: ViewNode?
        weak var storage: UpdatablePropertyStorage?
        weak var root: ViewNode?
        let revision: UInt64?
        let depth: Int
    }

    private var pending: [ObjectIdentifier: Entry] = [:]

    static func withUpdates<Result>(_ operation: () throws -> Result) rethrows -> Result {
        let previous = current
        let batch = StateUpdateBatch()
        current = batch
        defer {
            batch.flush()
            current = previous
        }
        return try operation()
    }

    func enqueue(_ node: ViewNode, storage: UpdatablePropertyStorage) {
        var root = node
        var depth = 0
        while let parent = root.parent {
            root = parent
            depth += 1
        }
        pending[ObjectIdentifier(node)] = Entry(
            node: node,
            storage: storage,
            root: root,
            revision: (node as? ViewContainerNode)?.contentObservationRevision,
            depth: depth
        )
    }

    func flush() {
        let entries = pending.values.sorted { $0.depth < $1.depth }
        pending.removeAll(keepingCapacity: true)
        let previous = Self.current
        Self.current = nil
        defer { Self.current = previous }

        for entry in entries {
            guard let node = entry.node, let storage = entry.storage else { continue }
            var root = node
            while let parent = root.parent { root = parent }
            guard root === entry.root else { continue }
            if let revision = entry.revision,
               (node as? ViewContainerNode)?.contentObservationRevision != revision {
                // A parent has already rebuilt this child using the final state.
                continue
            }
            node.withAncestorTransaction { storage.performUpdate(node) }
        }
    }
}
