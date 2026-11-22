import AdaECS
import AdaRender
import Synchronization

/// Retains only free, fully overwritten vertex and index storage for one render device.
final class UIGeometryBufferPool: Resource, Sendable {
    private static let byteLimit = 8 * 1024 * 1024
    private static let bufferLimit = 256

    private struct Key: Hashable {
        let label: String?
        let capacity: Int
    }

    private struct State {
        var device: (any RenderDevice)?
        var buffers: [Key: [any Buffer]] = [:]
        var bytes = 0
        var count = 0
    }

    /// A draw item and every submitted command buffer keep the same lease alive.
    final class Lease: Sendable {
        let buffer: any Buffer
        private let pool: UIGeometryBufferPool
        private let device: any RenderDevice
        private let label: String?

        init(buffer: any Buffer, label: String?, pool: UIGeometryBufferPool, device: any RenderDevice) {
            self.buffer = buffer
            self.label = label
            self.pool = pool
            self.device = device
        }

        deinit {
            pool.recycle(buffer, label: label, from: device)
        }
    }

    private let state = Mutex(State())

    func acquire(label: String?, byteCount: Int, device: any RenderDevice) -> Lease {
        let capacity = byteCount <= Self.byteLimit
            ? 1 << (Int.bitWidth - (byteCount - 1).leadingZeroBitCount)
            : byteCount
        let key = Key(label: label, capacity: capacity)
        let cached = state.withLock { state -> (any Buffer)? in
            if state.device !== device {
                state = State(device: device)
            }
            while true {
                // Give the popped buffer a single local owner before testing its aliases.
                var candidate: AnyObject? = state.buffers[key]?.popLast() as AnyObject?
                guard candidate != nil else {
                    return nil
                }
                state.bytes -= key.capacity
                state.count -= 1
                // A caller may still own the raw buffer independently of its draw item.
                if isKnownUniquelyReferenced(&candidate) {
                    return candidate as? any Buffer
                }
            }
        }
        let buffer: any Buffer
        if let cached {
            cached.label = label
            buffer = cached
        } else {
            buffer = device.createBuffer(label: label, length: capacity, options: .storageShared)
        }
        return Lease(buffer: buffer, label: label, pool: self, device: device)
    }

    private func recycle(_ buffer: any Buffer, label: String?, from device: any RenderDevice) {
        state.withLock { state in
            guard state.device === device,
                buffer.length <= Self.byteLimit - state.bytes,
                state.count < Self.bufferLimit
            else {
                return
            }
            let key = Key(label: label, capacity: buffer.length)
            state.buffers[key, default: []].append(buffer)
            state.bytes += buffer.length
            state.count += 1
        }
    }
}

extension CommandBuffer {
    func retainUIGeometry(_ leases: [UIGeometryBufferPool.Lease]) {
        guard !leases.isEmpty else {
            return
        }
        if let deferred = self as? any CommandBufferWithDeferredRetention {
            deferred.retainUntilRetired(leases)
        } else {
            addCompletedHandler { withExtendedLifetime(leases) {} }
        }
    }
}
