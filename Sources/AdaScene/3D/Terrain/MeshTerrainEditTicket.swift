import Synchronization

/// A preview may be superseded before the next world update.
/// The last world publication check and the next pointer sample use the same ticket.
public final class MeshTerrainEditTicket: Sendable {
    private enum State: Sendable { case pending, superseded, claimed }
    private let state = Mutex(State.pending)

    public init() {}

    public var isPending: Bool { state.withLock { $0 == .pending } }

    public func supersede() {
        state.withLock {
            if $0 == .pending { $0 = .superseded }
        }
    }

    var isSuperseded: Bool { state.withLock { $0 == .superseded } }

    func claim() -> Bool {
        state.withLock {
            guard $0 == .pending else { return false }
            $0 = .claimed
            return true
        }
    }
}
