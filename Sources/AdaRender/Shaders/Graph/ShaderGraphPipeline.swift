import Foundation

/// GPU creation stays on the caller's render context. Locks guard only bounded cache state.
final class ShaderGraphPipelineStorage: @unchecked Sendable {
    static let shared = ShaderGraphPipelineStorage()
    struct Key: Hashable {
        let device: ObjectIdentifier
        let vertex: ObjectIdentifier
        let layout: VertexDescriptor
        let variant: String
        let defines: [ShaderDefine]
        var source = ""
    }
    private let lock = NSLock()
    private var entries: [Key: (RenderDevice, Result<RenderPipeline, any Error>)] = [:]
    private var order: [Key] = []

    func resolve(_ key: Key, device: RenderDevice, cacheFailure: Bool, create: () throws -> RenderPipeline) throws -> RenderPipeline {
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[key] {
            return try cached.1.get()
        }
        do {
            let pipeline = try create()
            insert(.success(pipeline), key: key, device: device)
            return pipeline
        } catch {
            if cacheFailure { insert(.failure(error), key: key, device: device) }
            throw error
        }
    }

    private func insert(_ value: Result<RenderPipeline, any Error>, key: Key, device: RenderDevice) {
        if order.count >= 256, let first = order.first { entries.removeValue(forKey: first); order.removeFirst() }
        order.append(key)
        entries[key] = (device, value)
    }
}
