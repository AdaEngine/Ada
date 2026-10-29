import AdaECS
import AdaRender
import Foundation
import Math

/// Stable identity plus a component-owned update counter, including component replacement.
public struct SkinningPoseRevision: Sendable, Equatable {
    public let id: UUID
    public let generation: UInt64
    public init(id: UUID, generation: UInt64) {
        self.id = id
        self.generation = generation
    }
}

/// Reused, frame-buffered joint palettes shared by the main and shadow passes.
public struct Skinning3DUniforms: Resource {
    // 16 KiB fits WebGPU's guaranteed uniform-binding limit, and allows several
    // full humanoid rigs to share a page without reducing their bone count.
    public static let maximumJoints = 256
    public static let binding = 14
    private struct Entry {
        var buffers: [(any UniformBuffer)?]
        var frame: Int
        var previousBuffers: [(any UniformBuffer)?]
        var matrices: [Transform3D]
        var revision: SkinningPoseRevision?
        var uploaded: [SkinningPoseRevision?]
        var previousUploaded: [SkinningPoseRevision?]
        var isPacked = false
    }
    private var entries: [Entity.ID: Entry] = [:]
    private var frame = 0
    private var currentIndex = 0
    private let bufferCount: Int
    private var upload = [Transform3D](repeating: .identity, count: maximumJoints)
    private struct PackedPage {
        var current: [Transform3D] = Array(repeating: .identity, count: maximumJoints)
        var previous: [Transform3D] = Array(repeating: .identity, count: maximumJoints)
        var buffers: [(any UniformBuffer)?]
        var previousBuffers: [(any UniformBuffer)?]
        var used = 0
    }
    private var packedPages: [PackedPage] = []
    private var packedPage = 0
    private var packedOffsets: [Entity.ID: Int] = [:]
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
        for index in packedPages.indices { packedPages[index].used = 0 }
        packedPage = 0
        packedOffsets.removeAll(keepingCapacity: true)
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
        write(matrices, for: entity, device: device, revision: nil)
    }

    /// Joint base within a shared palette page. Non-packed entities use zero.
    public func packedOffset(for entity: Entity.ID) -> Int { packedOffsets[entity] ?? 0 }

    /// Packs exact current and previous poses into a shared uniform binding.
    /// Call finishPackedWrites once after all poses have been extracted.
    public mutating func writePacked(_ matrices: [Transform3D], for entity: Entity.ID,
        device: RenderDevice, revision: SkinningPoseRevision?) -> (any UniformBuffer)? {
        guard !matrices.isEmpty, matrices.count <= Self.maximumJoints else { return nil }
        if packedPages.indices.contains(packedPage), packedPages[packedPage].used + matrices.count > Self.maximumJoints {
            packedPage += 1
        }
        if !packedPages.indices.contains(packedPage) {
            packedPages.append(PackedPage(buffers: Array(repeating: nil, count: bufferCount),
                                          previousBuffers: Array(repeating: nil, count: bufferCount)))
        }
        if packedPages[packedPage].buffers[currentIndex] == nil {
            packedPages[packedPage].buffers[currentIndex] = device.createUniformBuffer(Transform3D.self, count: Self.maximumJoints, binding: Self.binding)
            packedPages[packedPage].previousBuffers[currentIndex] = device.createUniformBuffer(Transform3D.self, count: Self.maximumJoints, binding: 24)
        }
        let base = packedPages[packedPage].used
        let previous: [Transform3D]
        if let old = entries[entity], old.matrices.count == matrices.count, old.revision?.id == revision?.id { previous = old.matrices }
        else { previous = matrices }
        for index in matrices.indices {
            packedPages[packedPage].current[base + index] = matrices[index]
            packedPages[packedPage].previous[base + index] = previous[index]
        }
        packedPages[packedPage].used += matrices.count
        packedOffsets[entity] = base
        entries[entity] = Entry(buffers: packedPages[packedPage].buffers, frame: frame,
                               previousBuffers: packedPages[packedPage].previousBuffers, matrices: matrices, revision: revision,
                               uploaded: Array(repeating: nil, count: bufferCount), previousUploaded: Array(repeating: nil, count: bufferCount), isPacked: true)
        return packedPages[packedPage].buffers[currentIndex]
    }

    /// Upload each shared page once; all main, shadow and motion draws reuse it.
    public mutating func finishPackedWrites() {
        for index in packedPages.indices where packedPages[index].used > 0 {
            let current = packedPages[index].buffers[currentIndex]
            let previous = packedPages[index].previousBuffers[currentIndex]
            current?.setElements(&packedPages[index].current)
            previous?.setElements(&packedPages[index].previous)
        }
    }

    /// Reuses unchanged GPU palette uploads while keeping current/previous frame histories separate.
    public mutating func write(_ matrices: [Transform3D], for entity: Entity.ID, device: RenderDevice, revision: SkinningPoseRevision?) -> (any UniformBuffer)? {
        guard !matrices.isEmpty, matrices.count <= Self.maximumJoints else {
            return nil
        }
        packedOffsets.removeValue(forKey: entity)
        var entry =
            entries[entity]
            ?? Entry(
                buffers: Array(repeating: nil, count: bufferCount),
                frame: frame,
                previousBuffers: Array(repeating: nil, count: bufferCount),
                matrices: matrices,
                revision: revision,
                uploaded: Array(repeating: nil, count: bufferCount),
                previousUploaded: Array(repeating: nil, count: bufferCount)
            )
        if entry.isPacked {
            // Leaving a batch must never write an individual pose into a page
            // that still belongs to other instances.
            entry.buffers = Array(repeating: nil, count: bufferCount)
            entry.previousBuffers = Array(repeating: nil, count: bufferCount)
            entry.uploaded = Array(repeating: nil, count: bufferCount)
            entry.previousUploaded = Array(repeating: nil, count: bufferCount)
            entry.isPacked = false
        }
        if entry.previousBuffers[currentIndex] == nil {
            entry.previousBuffers[currentIndex] = device.createUniformBuffer(Transform3D.self, count: Self.maximumJoints, binding: 24)
        }
        let compatible = entry.matrices.count == matrices.count && entry.revision?.id == revision?.id
        let previous = compatible ? entry.matrices : matrices
        let previousRevision = compatible ? entry.revision : revision
        if revision == nil || entry.previousUploaded[currentIndex] != previousRevision {
            for index in upload.indices { upload[index] = index < previous.count ? previous[index] : .identity }
            entry.previousBuffers[currentIndex]?.setElements(&upload)
            entry.previousUploaded[currentIndex] = previousRevision
        }
        entry.matrices = matrices
        entry.revision = revision
        if entry.buffers[currentIndex] == nil {
            entry.buffers[currentIndex] = device.createUniformBuffer(Transform3D.self, count: Self.maximumJoints, binding: Self.binding)
        }
        if revision == nil || entry.uploaded[currentIndex] != revision {
            for index in upload.indices { upload[index] = index < matrices.count ? matrices[index] : .identity }
            entry.buffers[currentIndex]?.setElements(&upload)
            entry.uploaded[currentIndex] = revision
        }
        entry.frame = frame
        entries[entity] = entry
        return entry.buffers[currentIndex]
    }
}
