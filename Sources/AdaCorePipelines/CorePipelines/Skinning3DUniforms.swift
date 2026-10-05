import AdaECS
import AdaRender
import Math

/// Reused, frame-buffered joint palettes shared by the main and shadow passes.
public struct Skinning3DUniforms: Resource {
    public static let maximumJoints = 128
    public static let binding = 14
    private struct Entry {
        var buffers: [(any UniformBuffer)?]
        var frame: Int
        var previousBuffers: [(any UniformBuffer)?]
        var matrices: [Transform3D]
    }
    private var entries: [Entity.ID: Entry] = [:]
    private var frame = 0
    private var currentIndex = 0
    private let bufferCount: Int
    private var upload = [Transform3D](repeating: .identity, count: maximumJoints)
    public private(set) var identityBuffer: (any UniformBuffer)?

    public init() {
        bufferCount = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
    }

    public mutating func beginFrame(device: RenderDevice) {
        for (entity, entry) in entries where entry.frame != frame {
            entries.removeValue(forKey: entity)
        }
        frame &+= 1
        currentIndex = (currentIndex + 1) % bufferCount
        if identityBuffer == nil {
            identityBuffer = device.createUniformBuffer(Transform3D.self, count: Self.maximumJoints, binding: Self.binding)
            identityBuffer?.setElements(&upload)
        }
    }

    public func buffer(for entity: Entity.ID) -> (any UniformBuffer)? {
        guard let entry = entries[entity], entry.frame == frame else {
            return nil
        }
        return entry.buffers[currentIndex]
    }

    public func previousBuffer(for entity: Entity.ID) -> (any UniformBuffer)? {
        guard let entry = entries[entity], entry.frame == frame else {
            return nil
        }
        return entry.previousBuffers[currentIndex]
    }

    public mutating func write(_ matrices: [Transform3D], for entity: Entity.ID, device: RenderDevice) -> (any UniformBuffer)? {
        guard !matrices.isEmpty, matrices.count <= Self.maximumJoints else {
            return nil
        }
        var entry = entries[entity] ?? Entry(
            buffers: Array(repeating: nil, count: bufferCount),
            frame: frame,
            previousBuffers: Array(repeating: nil, count: bufferCount),
            matrices: matrices
        )
        if entry.previousBuffers[currentIndex] == nil {
            entry.previousBuffers[currentIndex] = device.createUniformBuffer(Transform3D.self, count: Self.maximumJoints, binding: 24)
        }
        let previous = entry.matrices.count == matrices.count ? entry.matrices : matrices
        for index in upload.indices { upload[index] = index < previous.count ? previous[index] : .identity }
        entry.previousBuffers[currentIndex]?.setElements(&upload)
        entry.matrices = matrices
        if entry.buffers[currentIndex] == nil {
            entry.buffers[currentIndex] = device.createUniformBuffer(Transform3D.self, count: Self.maximumJoints, binding: Self.binding)
        }
        for index in upload.indices { upload[index] = index < matrices.count ? matrices[index] : .identity }
        entry.buffers[currentIndex]?.setElements(&upload)
        entry.frame = frame
        entries[entity] = entry
        return entry.buffers[currentIndex]
    }
}
