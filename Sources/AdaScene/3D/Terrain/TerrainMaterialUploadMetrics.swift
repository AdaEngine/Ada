import AdaECS
import Synchronization

/// Optional world-local profiling of material image bytes submitted by terrain publication.
final class TerrainMaterialUploadMetrics: Resource, Sendable {
    private let bytes = Mutex<UInt64>(0)

    var uploadedBytes: UInt64 { bytes.withLock { $0 } }

    func record(bytes count: Int) { bytes.withLock { $0 &+= UInt64(count) } }
}
