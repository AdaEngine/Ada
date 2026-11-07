import AdaECS
import Synchronization

/// Counts actual native BVH creations attributable to a physics world, including terrain staging.
/// Read snapshot differences to measure work performed in a frame; no simulation tick is required.
public final class PhysicsCollisionPreparationMetrics: Resource, Sendable {
    public struct Snapshot: Sendable {
        public let nativeTriangleMeshCount: UInt64
        public let triangleCount: UInt64
    }

    private struct State: Sendable {
        var nativeTriangleMeshCount: UInt64 = 0
        var triangleCount: UInt64 = 0
    }
    private let state = Mutex(State())

    public init() {}

    public var snapshot: Snapshot {
        state.withLock { .init(nativeTriangleMeshCount: $0.nativeTriangleMeshCount, triangleCount: $0.triangleCount) }
    }

    func recordTriangleMesh(triangleCount: Int) {
        state.withLock { value in
            value.nativeTriangleMeshCount &+= 1
            value.triangleCount &+= UInt64(triangleCount)
        }
    }
}
