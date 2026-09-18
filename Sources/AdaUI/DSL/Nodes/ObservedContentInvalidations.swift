// Observation callbacks can arrive for both a parent and its descendants.
// Process parents first and let each node reject callbacks from a body that
// has already been replaced. Merely having a dirty ancestor is not sufficient
// to discard a child's independent change.
@MainActor
final class ObservedContentInvalidations {
    static let shared = ObservedContentInvalidations()

    private struct Entry {
        weak var node: ViewContainerNode?
        let revision: UInt64
    }

    private var pending: [ObjectIdentifier: Entry] = [:]
    private var isScheduled = false

    func enqueue(_ node: ViewContainerNode, revision: UInt64) {
        pending[ObjectIdentifier(node)] = Entry(node: node, revision: revision)
        guard !isScheduled else {
            return
        }
        isScheduled = true
        Task { @MainActor in
            self.flush()
        }
    }

    private func flush() {
        let batch = pending.values
            .map { entry in
                var depth = 0
                var ancestor = entry.node?.parent
                while let node = ancestor {
                    depth += 1
                    ancestor = node.parent
                }
                return (entry: entry, depth: depth)
            }
            .sorted { $0.depth < $1.depth }
        pending.removeAll(keepingCapacity: true)
        isScheduled = false

        for item in batch {
            item.entry.node?.performObservedContentInvalidation(revision: item.entry.revision)
        }
    }
}
