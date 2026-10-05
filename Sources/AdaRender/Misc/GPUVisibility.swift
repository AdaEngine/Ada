import Math

/// Binary layout shared by Metal/WebGPU indexed indirect draws (five 32-bit words).
public struct IndexedIndirectArguments: Sendable {
    public var indexCount: UInt32
    public var instanceCount: UInt32
    public var firstIndex: UInt32
    public var baseVertex: Int32
    public var firstInstance: UInt32

    public init(indexCount: UInt32, instanceCount: UInt32 = 0, firstIndex: UInt32 = 0, baseVertex: Int32 = 0, firstInstance: UInt32 = 0) {
        self.indexCount = indexCount
        self.instanceCount = instanceCount
        self.firstIndex = firstIndex
        self.baseVertex = baseVertex
        self.firstInstance = firstInstance
    }
}

/// One packed instance, with conservative world bounds and its destination draw/segment.
public struct GPUVisibilityCandidate: Sendable {
    public var minimum: Vector4
    public var maximum: Vector4
    public var draw: UInt32
    public var source: UInt32
    public var destination: UInt32
    public var forceVisible: UInt32

    public init(bounds: AABB?, draw: UInt32, source: UInt32, destination: UInt32, forceVisible: Bool) {
        minimum = Vector4(bounds?.min ?? .zero, 0)
        maximum = Vector4(bounds?.max ?? .zero, 0)
        self.draw = draw
        self.source = source
        self.destination = destination
        self.forceVisible = forceVisible || bounds == nil ? 1 : 0
    }
}

public struct GPUVisibilityOutput: Sendable {
    public let instances: any Buffer
    public let arguments: any Buffer
    public let drawCount: Int
    public init(instances: any Buffer, arguments: any Buffer, drawCount: Int) {
        self.instances = instances
        self.arguments = arguments
        self.drawCount = drawCount
    }
}

/// Encodes current-frame Hi-Z reduction and instance compaction after an opaque depth prepass.
/// No previous-frame depth is consumed, so camera cuts, moved objects and removed occluders
/// cannot reject newly visible geometry. Shadow lists remain independent from this processor.
public protocol GPUVisibilityProcessor: AnyObject, Sendable {
    func encode(
        on command: any CommandBuffer,
        depth: Texture,
        viewProjection: Transform3D,
        instances: any Buffer,
        instanceStride: Int,
        candidates: [GPUVisibilityCandidate],
        draws: [IndexedIndirectArguments]
    ) -> GPUVisibilityOutput?
}
