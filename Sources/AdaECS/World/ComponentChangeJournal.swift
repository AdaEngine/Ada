import Atomics
import Synchronization

/// Opt-in changes for consumers that cannot use a scheduler's tick interval.
/// Sequence numbers also distinguish writes between two extractions in the same tick.
@usableFromInline
package final class ComponentChangeJournal: Sendable {
    package struct Change: Sendable {
        package let entity: Entity.ID
        /// A nil component records an entity or archetype membership change.
        package let component: ComponentId?
    }

    private struct State {
        var components: Set<ComponentId> = []
        var changes: [Change] = []
        var sequence: UInt64 = 0
    }

    private static let capacity = 32_768
    private let active = ManagedAtomic(false)
    private let untrackedAccess = ManagedAtomic(false)
    private let state = Mutex(State())

    package func observe(_ components: Set<ComponentId>) -> UInt64 {
        let cursor = state.withLock {
            $0.components.formUnion(components)
            return $0.sequence
        }
        if !untrackedAccess.load(ordering: .acquiring) {
            active.store(true, ordering: .releasing)
        }
        return cursor
    }

    func disableSparseReads() {
        untrackedAccess.store(true, ordering: .releasing)
        active.store(false, ordering: .releasing)
    }

    func observes(_ component: ComponentId) -> Bool {
        active.load(ordering: .acquiring) && state.withLock { $0.components.contains(component) }
    }

    func record(entity: Entity.ID, component: ComponentId? = nil) {
        guard active.load(ordering: .acquiring) else {
            return
        }
        state.withLock { state in
            if let component, !state.components.contains(component) {
                return
            }
            Self.append(Change(entity: entity, component: component), to: &state)
        }
    }

    func recordMembership(entity: Entity.ID, before: ComponentMaskSet?, after: ComponentMaskSet?) {
        guard active.load(ordering: .acquiring) else {
            return
        }
        state.withLock { state in
            let changed = state.components.contains { component in
                (before?.contains(component) ?? false) != (after?.contains(component) ?? false)
            }
            if changed { Self.append(Change(entity: entity, component: nil), to: &state) }
        }
    }

    private static func append(_ change: Change, to state: inout State) {
        let slot = Int(state.sequence % UInt64(capacity))
        if slot < state.changes.count {
            state.changes[slot] = change
        } else {
            state.changes.append(change)
        }
        state.sequence &+= 1
    }

    func invalidate() {
        guard active.load(ordering: .acquiring) else {
            return
        }
        state.withLock {
            $0.changes.removeAll(keepingCapacity: true)
            // Start a fresh ring at slot zero without reusing any previous cursor.
            $0.sequence &+= UInt64(Self.capacity) - $0.sequence % UInt64(Self.capacity)
        }
    }

    package func read(after cursor: UInt64) -> (cursor: UInt64, changes: [Change]?) {
        state.withLock { state in
            let count = state.sequence &- cursor
            guard !untrackedAccess.load(ordering: .acquiring), count <= UInt64(state.changes.count) else {
                return (state.sequence, nil)
            }
            let changes = (0..<count).map { offset in
                state.changes[Int((cursor &+ offset) % UInt64(Self.capacity))]
            }
            return (state.sequence, changes)
        }
    }
}

@usableFromInline
struct ObservedComponentWrite: Sendable {
    let journal: ComponentChangeJournal
    let entity: Entity.ID
    let component: ComponentId

    @usableFromInline
    init(journal: ComponentChangeJournal, entity: Entity.ID, component: ComponentId) {
        self.journal = journal
        self.entity = entity
        self.component = component
    }

    func record() {
        journal.record(entity: entity, component: component)
    }
}
