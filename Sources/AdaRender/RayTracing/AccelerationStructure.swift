import Math

/// What an acceleration structure holds, and how much it can hold.
public enum AccelerationStructureKind: Equatable, Sendable {
    /// Triangle geometry of one mesh part, shared by every instance of it.
    case bottomLevel(triangleCapacity: Int)
    /// Placed instances of bottom-level structures; this is what a ray query traverses.
    case topLevel(instanceCapacity: Int)
}

/// A GPU ray-tracing acceleration structure. Create one through ``RenderDevice``; backends that cannot trace rays return nil.
public protocol AccelerationStructure: AnyObject, Sendable {
    var kind: AccelerationStructureKind { get }
}

/// Why an acceleration-structure input was rejected.
public enum AccelerationStructureError: Error, Equatable, Sendable {
    case invalid(String)
}

/// Triangles to build a bottom-level structure from. Positions are three tightly read 32-bit floats per vertex.
public struct AccelerationStructureGeometry: Sendable {
    public var vertexBuffer: any Buffer
    /// Byte offset of the first position.
    public var vertexOffset: Int
    /// Bytes between consecutive positions (at least 12, a multiple of 4).
    public var vertexStride: Int
    public var vertexCount: Int
    /// Optional 16- or 32-bit triangle-list indices; without them every three vertices are a triangle.
    public var indexBuffer: (any IndexBuffer)?
    public var indexCount: Int

    public init(
        vertexBuffer: any Buffer, vertexOffset: Int = 0, vertexStride: Int = 12, vertexCount: Int,
        indexBuffer: (any IndexBuffer)? = nil, indexCount: Int = 0
    ) {
        self.vertexBuffer = vertexBuffer
        self.vertexOffset = vertexOffset
        self.vertexStride = vertexStride
        self.vertexCount = vertexCount
        self.indexBuffer = indexBuffer
        self.indexCount = indexCount
    }

    public var triangleCount: Int { (indexBuffer == nil ? vertexCount : indexCount) / 3 }

    /// Throws ``AccelerationStructureError`` when the layout cannot be built.
    public func validate() throws {
        guard vertexStride >= 12, vertexStride % 4 == 0 else {
            throw AccelerationStructureError.invalid("The vertex stride must be at least 12 bytes and a multiple of 4")
        }
        guard vertexOffset >= 0, vertexOffset % 4 == 0 else {
            throw AccelerationStructureError.invalid("The vertex offset must be a non-negative multiple of 4")
        }
        guard vertexCount > 0 else { throw AccelerationStructureError.invalid("There are no vertices") }
        guard vertexOffset + (vertexCount - 1) * vertexStride + 12 <= vertexBuffer.length else {
            throw AccelerationStructureError.invalid("The positions extend past the end of the vertex buffer")
        }
        guard let indexBuffer else {
            guard vertexCount % 3 == 0 else { throw AccelerationStructureError.invalid("A triangle list needs a multiple of 3 vertices") }
            return
        }
        guard indexCount > 0, indexCount % 3 == 0 else {
            throw AccelerationStructureError.invalid("A triangle list needs a positive multiple of 3 indices")
        }
        let indexSize = indexBuffer.indexFormat == .uInt16 ? 2 : 4
        guard indexCount * indexSize <= indexBuffer.length else {
            throw AccelerationStructureError.invalid("The indices extend past the end of the index buffer")
        }
    }
}

/// A bottom-level structure placed in a top-level structure.
public struct AccelerationStructureInstance: Sendable {
    public var structure: any AccelerationStructure
    public var transform: Transform3D
    /// Rays select instances with a mask; shadow rays use it to find shadow casters.
    public var mask: UInt8
    /// Returned with a hit as the instance's custom data.
    public var instanceID: UInt32

    public init(structure: any AccelerationStructure, transform: Transform3D = .identity, mask: UInt8 = 0xff, instanceID: UInt32 = 0) {
        self.structure = structure
        self.transform = transform
        self.mask = mask
        self.instanceID = instanceID
    }

    /// The affine transform as 12 row-major floats with the translation in the last column.
    public var rowMajor3x4: [Float] {
        [
            transform.x.x, transform.y.x, transform.z.x, transform.w.x,
            transform.x.y, transform.y.y, transform.z.y, transform.w.y,
            transform.x.z, transform.y.z, transform.z.z, transform.w.z,
        ]
    }
}
