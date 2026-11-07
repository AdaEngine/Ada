import AdaECS
import Synchronization

/// Pauses physical movement while providers prepare coherent collision. Providers release only their own reason.
public final class PhysicsSimulationGate3D: Resource, Sendable {
    private let pending = Mutex<[Entity.ID: Set<String>]>([:])

    public init() {}

    public var isReady: Bool { pending.withLock { $0.isEmpty } }
    public var pendingOwnerCount: Int { pending.withLock { $0.count } }

    public func setPending(owner: Entity.ID, reason: String, pending isPending: Bool) {
        pending.withLock { values in
            if isPending {
                values[owner, default: []].insert(reason)
            } else {
                values[owner]?.remove(reason)
                if values[owner]?.isEmpty == true { values.removeValue(forKey: owner) }
            }
        }
    }
}
