//
//  MeshDescriptor.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/9/21.
//

import AdaUtils
import Math
import OrderedCollections

#if canImport(Metal) && METAL
    import Metal
#endif

/// An object that defines a mesh.
/// This struct contains all the mesh data.
public struct MeshDescriptor: Sendable {
    /// Descriptors for the buffers.
    public internal(set) var buffers: OrderedDictionary<MeshDescriptor.Identifier, AnyMeshBuffer> = [:]

    /// Name of the mesh.
    public var name: String

    public enum Materials: Sendable {
        case allFaces(UInt32)
        case perFace([UInt32])
    }

    /// Material assignments.
    public var materials: Materials = .allFaces(0)

    /// The primitives that make up the mesh.
    public var primitiveTopology: Mesh.PrimitiveTopology = .triangleList

    /// The indices of the mesh.
    public var indicies: [UInt32] = []

    /// Create an empty mesh descriptor.
    @_spi(Internal)
    public init(name: String) {
        self.name = name
        buffers[.positions] = AnyMeshBuffer(MeshBuffer<Vector3>([]))
    }

    /// Get the buffer for a given semantic. There can only be one buffer for any given ID.
    public subscript<S>(semantic: S) -> MeshBuffer<S.Element>? where S: MeshArraySemantic {
        get {
            buffers[semantic.id]?.get(as: S.Element.self)
        }
        set {
            buffers[semantic.id] = newValue.flatMap { AnyMeshBuffer($0) }
        }
    }
}

public extension Mesh {
    /// The type of the elements in the mesh.
    enum ElementType: UInt8, Sendable {
        case int8
        case uint8
        case int16
        case uint16
        case int32
        case uint32

        case float

        case vector2
        case vector3
        case vector4
    }

    /// The type of the array in the mesh.
    enum ArrayType: UInt8, Sendable {
        case vertex
        case normal
        case textureUV
        case color
        case tangent
        case index
    }

    /// The primitive topology of the mesh.
    enum PrimitiveTopology: UInt8, Sendable {
        case points
        case triangleList
        case triangleStrip
        case lineList
        case lineStrip
    }
}

/// A protocol that represents a semantic of a mesh array.
public protocol MeshArraySemantic: Identifiable, Sendable {
    /// The type of the elements in the mesh array.
    associatedtype Element

    /// The identifier of the mesh array semantic.

    var id: MeshDescriptor.Identifier { get }
}

public extension MeshDescriptor {
    /// An identifier for a mesh attribute.
    struct Identifier: Identifiable, Hashable, Sendable {
        public var id: String {
            name
        }

        /// The name of the identifier.
        public let name: String

        /// Whether the identifier is custom.
        public let isCustom: Bool

        /// A position attribute identifier.
        public static let positions: MeshDescriptor.Identifier = .init(name: "positions", isCustom: false)

        /// A normal attribute identifier.
        public static let normals: MeshDescriptor.Identifier = .init(name: "normals", isCustom: false)

        /// A tangent attribute identifier.
        public static let tangents: MeshDescriptor.Identifier = .init(name: "tangents", isCustom: false)

        /// A texture coordinates attribute identifier.
        public static let textureCoordinates: MeshDescriptor.Identifier = .init(name: "textureCoordinates", isCustom: false)

        public static let textureCoordinates1 = MeshDescriptor.Identifier(name: "textureCoordinates1", isCustom: false)
        public static let jointIndices = MeshDescriptor.Identifier(name: "jointIndices", isCustom: false)
        public static let jointWeights = MeshDescriptor.Identifier(name: "jointWeights", isCustom: false)

        /// A colors attribute identifier.
        public static let colors: MeshDescriptor.Identifier = .init(name: "colors", isCustom: false)
    }

    /// A semantic of a mesh array.
    struct Semantic<Element>: MeshArraySemantic {
        /// The stable identity of the entity associated with this instance.
        public let id: MeshDescriptor.Identifier

        /// A type representing the stable identity of the entity associated with
        /// an instance.
        public typealias ID = MeshDescriptor.Identifier
    }

    /// A semantic of a mesh array for positions.
    static let positions: MeshDescriptor.Semantic<Vector3> = .init(id: .positions)

    /// A semantic of a mesh array for normals.
    static let normals: MeshDescriptor.Semantic<Vector3> = .init(id: .normals)

    /// A semantic of a mesh array for tangents.
    static let tangents: MeshDescriptor.Semantic<Vector4> = .init(id: .tangents)

    /// A semantic of a mesh array for texture coordinates.
    static let textureCoordinates: MeshDescriptor.Semantic<Vector2> = .init(id: .textureCoordinates)

    /// A semantic of a mesh array for colors.
    static let colors: MeshDescriptor.Semantic<Color> = .init(id: .colors)

    /// Four palette indices per vertex, represented exactly as floats for vertex input portability.
    static let textureCoordinates1 = MeshDescriptor.Semantic<Vector2>(id: .textureCoordinates1)
    static let jointIndices = MeshDescriptor.Semantic<Vector4>(id: .jointIndices)
    static let jointWeights = MeshDescriptor.Semantic<Vector4>(id: .jointWeights)

    /// Create a custom semantic of a mesh array.
    static func custom<Value>(_ name: String, type _: Value.Type) -> MeshDescriptor.Semantic<Value> {
        Semantic<Value>(id: Identifier(name: name, isCustom: true))
    }
}

public extension MeshDescriptor {
    /// A buffer for positions.
    typealias Positions = MeshBuffer<Vector3>

    /// A buffer for normals.
    typealias Normals = MeshBuffer<Vector3>

    /// A buffer for texture coordinates.
    typealias TextureCoordinates = MeshBuffer<Vector2>

    /// A buffer for tangent vectors and their handedness.
    typealias Tangents = MeshBuffer<Vector4>

    /// A buffer for colors.
    typealias Colors = MeshBuffer<Color>

    /// The buffer for positions.
    var positions: MeshDescriptor.Positions {
        get {
            self[Self.positions].unwrap(message: "A mesh descriptor must contain a positions buffer.")
        }

        set {
            self[Self.positions] = newValue
        }
    }

    /// The buffer for normals.
    var normals: MeshDescriptor.Normals? {
        _read {
            yield self[Self.normals]
        }
        _modify {
            yield &self[Self.normals]
        }
    }

    /// The buffer for texture coordinates.
    var textureCoordinates: MeshDescriptor.TextureCoordinates? {
        _read {
            yield self[Self.textureCoordinates]
        }

        _modify {
            yield &self[Self.textureCoordinates]
        }
    }

    /// The buffer for tangent vectors and their handedness.
    var tangents: MeshDescriptor.Tangents? {
        _read {
            yield self[Self.tangents]
        }
        _modify {
            yield &self[Self.tangents]
        }
    }

    /// The buffer for colors.
    var colors: MeshDescriptor.Colors? {
        _read {
            yield self[Self.colors]
        }
        _modify {
            yield &self[Self.colors]
        }
    }
}

public extension MeshDescriptor {
    /// Get the vertex buffer descriptor for the mesh.
    func getMeshVertexBufferDescriptor() -> VertexDescriptor {
        var vertexDescriptor = VertexDescriptor()

        var offset = 0
        var usedLocations = Set(buffers.elements.compactMap(\.key.vertexShaderLocation))
        var nextCustomLocation = 0
        for value in buffers.elements {
            let buffer = value.value.buffer
            let attribute = value.key
            let location =
                attribute.vertexShaderLocation
                    ?? {
                        while usedLocations.contains(nextCustomLocation) {
                            nextCustomLocation += 1
                        }
                        return nextCustomLocation
                    }()

            vertexDescriptor.attributes[location].name = attribute.name
            vertexDescriptor.attributes[location].format = buffer.elementType.vertexFormat
            vertexDescriptor.attributes[location].offset = offset

            usedLocations.insert(location)
            offset += buffer.elementSize
        }

        vertexDescriptor.layouts[0].stride = offset

        return vertexDescriptor
    }

    /// Get the size of the vertex buffer.
    func getVertexBufferSize() -> Int {
        buffers.elements.values.reduce(into: 0) { partialResult, buffer in
            partialResult += buffer.buffer.elementSize * buffer.count
        }
    }

    /// Get the index buffer for the mesh.
    func getIndexBuffer(renderDevice: RenderDevice) -> IndexBuffer {
        var indicies = indicies
        let indexBuffer = unsafe renderDevice.createIndexBuffer(
            format: .uInt32,
            bytes: &indicies,
            length: indicies.count * MemoryLayout<UInt32>.stride
        )

        return indexBuffer
    }

    /// Get the vertex buffer for the mesh.
    func getVertexBuffer(renderDevice: RenderDevice, binding: Int = 0) -> VertexBuffer {
        let vertexBufferSize = getVertexBufferSize()
        let vertexBuffer = renderDevice.createVertexBuffer(
            length: vertexBufferSize,
            binding: binding
        )
        var vertexBufferBytes = [UInt8](repeating: 0, count: vertexBufferSize)

        // Calculate stride (per-vertex size) as the sum of all attribute element sizes
        let stride = buffers.elements.values.reduce(0) { $0 + $1.buffer.elementSize }

        unsafe vertexBufferBytes.withUnsafeMutableBytes { vertexBufferContents in
            guard let baseAddress = vertexBufferContents.baseAddress else {
                return
            }

            var attributeOffset = 0
            for buffer in buffers.elements.values {
                let elementSize = buffer.buffer.elementSize

                unsafe buffer.buffer.iterateByElements { index, pointer in
                    let offset = index * stride + attributeOffset
                    unsafe baseAddress
                        .advanced(by: offset)
                        .copyMemory(from: pointer, byteCount: elementSize)
                }

                attributeOffset += elementSize
            }
        }

        unsafe vertexBufferBytes.withUnsafeMutableBytes { vertexBufferContents in
            guard let baseAddress = vertexBufferContents.baseAddress else {
                return
            }
            unsafe vertexBuffer.setData(baseAddress, byteCount: vertexBufferSize)
        }

        return vertexBuffer
    }
}

extension MeshDescriptor.Identifier {
    var vertexShaderLocation: Int? {
        switch self {
        case .positions:
            0
        case .normals:
            1
        case .textureCoordinates:
            2
        case .colors:
            3
        case .tangents:
            4
        case .jointIndices:
            13
        case .jointWeights:
            14
        case .textureCoordinates1:
            15
        default:
            nil
        }
    }
}

extension Mesh.ElementType {
    /// Get the vertex format for the element type.
    var vertexFormat: VertexFormat {
        switch self {
        case .int8:
            .int
        case .uint8:
            .uint
        case .int16:
            .uint
        case .uint16:
            .uint
        case .int32:
            .uint
        case .uint32:
            .uint
        case .float:
            .float
        case .vector2:
            .vector2
        case .vector3:
            .vector3
        case .vector4:
            .vector4
        }
    }
}

#if canImport(Metal) && METAL
    extension Mesh.PrimitiveTopology {
        /// Get the Metal primitive type for the primitive topology.
        var metal: MTLPrimitiveType {
            switch self {
            case .lineList: .line
            case .lineStrip: .lineStrip
            case .points: .point
            case .triangleStrip: .triangleStrip
            case .triangleList: .triangle
            }
        }
    }
#endif
