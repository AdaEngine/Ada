//
//  VertexDescriptor.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/3/21.
//

import Foundation
import Math

#if METAL
    import MetalKit
    import ModelIO
#endif

/// An array of vertex attribute descriptor objects.
public struct VertexDescriptorAttributesArray: Sequence, Codable, Hashable, Sendable {
    public typealias Element = VertexDescriptor.Attribute
    public typealias Iterator = Array<VertexDescriptor.Attribute>.Iterator

    /// Initialize a new vertex descriptor attributes array.
    /// - Parameter buffer: The array of attributes to initialize the vertex descriptor attributes array with.
    public init(buffer: [VertexDescriptor.Attribute] = []) {
        self.buffer = buffer
    }

    /// The count of attributes in the vertex descriptor.
    public var count: Int { self.buffer.count }

    /// The array of attributes in the vertex descriptor.
    internal var buffer: [VertexDescriptor.Attribute] = []

    /// Get or set the attribute at the given index.
    /// - Parameter index: The index of the attribute.
    /// - Returns: The attribute at the given index.
    public subscript(index: Int) -> VertexDescriptor.Attribute {
        mutating get {
            while !self.buffer.indices.contains(index) {
                self.buffer.append(Self.invalidAttribute())
            }

            return self.buffer[index]
        }

        set {
            while !self.buffer.indices.contains(index) {
                self.buffer.append(Self.invalidAttribute())
            }

            self.buffer[index] = newValue
        }
    }

    /// Whether the vertex descriptor contains an attribute with the given name.
    /// - Parameter name: The name of the attribute.
    /// - Returns: Whether the vertex descriptor contains an attribute with the given name.
    public func containsAttribute(by name: String) -> Bool {
        self.buffer.contains {
            $0.name == name
        }
    }

    /// Make an iterator over the attributes in the vertex descriptor.
    /// - Returns: An iterator over the attributes in the vertex descriptor.
    public func makeIterator() -> Iterator {
        return buffer.makeIterator()
    }

    /// Append an array of attributes to the vertex descriptor.
    /// - Parameter attributes: The array of attributes to append.
    public mutating func append(_ attributes: [VertexDescriptor.Attribute]) {
        var lastOffset: Int = 0

        for var attribute in attributes {
            if attribute.offset != VertexDescriptor.autocalculationOffset {
                lastOffset = attribute.offset
            }

            attribute.offset = lastOffset
            lastOffset += attribute.format.offset

            self.buffer.append(attribute)
        }
    }

    private static func invalidAttribute() -> VertexDescriptor.Attribute {
        VertexDescriptor.Attribute(name: "", offset: 0, bufferIndex: 0, format: .invalid)
    }
}

/// An array of vertex buffer layout descriptor objects.
public struct VertexDescriptorLayoutsArray: Sequence, Codable, Hashable, Sendable {
    public typealias Element = VertexDescriptor.Layout
    public typealias Iterator = Array<VertexDescriptor.Layout>.Iterator

    internal private(set) var buffer: [VertexDescriptor.Layout] = []

    /// The count of layouts in the vertex descriptor.
    public var count: Int { self.buffer.count }

    /// Initialize a new vertex descriptor layouts array.
    /// - Parameter buffer: The array of layouts to initialize the vertex descriptor layouts array with.
    public init(buffer: [VertexDescriptor.Layout] = []) {
        self.buffer = buffer
    }

    /// Get or set the layout at the given index.
    /// - Parameter index: The index of the layout.
    /// - Returns: The layout at the given index.
    public subscript(index: Int) -> VertexDescriptor.Layout {
        mutating get {
            while !self.buffer.indices.contains(index) {
                self.buffer.append(VertexDescriptor.Layout(stride: 0))
            }

            return self.buffer[index]
        }

        set {
            while !self.buffer.indices.contains(index) {
                self.buffer.append(VertexDescriptor.Layout(stride: 0))
            }

            self.buffer[index] = newValue
        }
    }

    /// Make an iterator over the layouts in the vertex descriptor.
    /// - Returns: An iterator over the layouts in the vertex descriptor.
    public func makeIterator() -> Iterator {
        return buffer.makeIterator()
    }
}

/// Values that specify the organization of function vertex data.
public enum VertexFormat: UInt, Codable, Sendable {
    case invalid

    case uint
    case char
    case short
    case int

    case float

    case vector4
    case vector3
    case vector2

    var offset: Int {
        switch self {
        case .invalid: return 0
        case .uint: return MemoryLayout<UInt>.stride
        case .char: return MemoryLayout<UInt8>.stride
        case .short: return MemoryLayout<UInt16>.stride
        case .int: return MemoryLayout<Int>.stride
        case .float: return MemoryLayout<Float>.stride
        case .vector4: return MemoryLayout<Vector4>.stride
        case .vector3: return MemoryLayout<Vector3>.stride
        case .vector2: return MemoryLayout<Vector2>.stride
        }
    }
}

/// An object that describes how to organize and map data to a vertex function.
///
/// This object is used to configure how vertex data stored in memory is mapped to attributes in a vertex shader.
/// A pipeline state is the state of the graphics rendering pipeline, including shaders, blending,
/// multisampling, and visibility testing. For every pipeline state, there can be only one VertexDescriptor object.
public struct VertexDescriptor: Codable, Hashable, Sendable {
    /// An array of state data that describes how vertex attribute data is stored in memory and is mapped to arguments for a vertex shader.
    public var attributes: VertexDescriptorAttributesArray

    /// An array of state data that describes how data are fetched by a vertex shader when rendering primitives.
    public var layouts: VertexDescriptorLayoutsArray

    /// The autocalculation offset for the vertex descriptor.
    public static let autocalculationOffset: Int = -2018

    /// An object that determines how to store attribute data in memory and map it to the arguments of a vertex shader.
    public struct Attribute: CustomStringConvertible, Codable, Hashable, Sendable {
        /// The name of an attribute in vertex data.
        public var name: String

        /// The location of an attribute in vertex data, determined by the byte offset from the start of the vertex data.
        public var offset: Int

        /// The index in the argument table for the associated vertex buffer.
        public var bufferIndex: Int

        /// The format of the vertex attribute.
        public var format: VertexFormat

        /// Create an attribute.
        /// - Parameter format: The format of the vertex attribute.
        /// - Parameter name: The name of an attribute.
        /// - Parameter bufferIndex: The index in the argument table for the associated vertex buffer.
        /// - Parameter offset: Location of an attribute in vertex data. By default is auto incrementable.
        public static func attribute(_ format: VertexFormat, name: String, bufferIndex: Int = 0, offset: Int = autocalculationOffset) -> Self {
            Self(name: name, offset: offset, bufferIndex: bufferIndex, format: format)
        }

        // MARK: - CustomStringConvertible

        public var description: String {
            return "Attribute: name=\(name) offset=\(offset) bufferIndex=\(bufferIndex) format=\(format)"
        }
    }

    /// An object that configures how a render pipeline fetches data to send to the vertex function.
    public struct Layout: CustomStringConvertible, Codable, Hashable, Sendable {
        public enum StepFunction: UInt, Codable, Sendable {
            case perVertex
            case perInstance
        }

        /// The distance, in bytes, between the attribute data of two vertices in the buffer.
        public var stride: Int

        /// How frequently the vertex buffer advances while drawing.
        public var stepFunction: StepFunction

        public init(stride: Int, stepFunction: StepFunction = .perVertex) {
            self.stride = stride
            self.stepFunction = stepFunction
        }

        private enum CodingKeys: String, CodingKey {
            case stride
            case stepFunction
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.stride = try container.decode(Int.self, forKey: .stride)
            self.stepFunction = try container.decodeIfPresent(StepFunction.self, forKey: .stepFunction) ?? .perVertex
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stride, forKey: .stride)
            try container.encode(stepFunction, forKey: .stepFunction)
        }

        public var description: String {
            return "Layout: stride=\(stride) stepFunction=\(stepFunction)"
        }
    }

    /// Initialize a new vertex descriptor.
    public init() {
        self.attributes = VertexDescriptorAttributesArray()
        self.layouts = VertexDescriptorLayoutsArray()
    }

    /// Initialize a new vertex descriptor.
    /// - Parameter attributes: The attributes of the vertex descriptor.
    /// - Parameter layouts: The layouts of the vertex descriptor.
    init(attributes: VertexDescriptorAttributesArray, layouts: VertexDescriptorLayoutsArray) {
        self.attributes = attributes
        self.layouts = layouts
    }

    /// Reset the default state for the vertex descriptor.
    public mutating func reset() {
        self.attributes = VertexDescriptorAttributesArray()
        self.layouts = VertexDescriptorLayoutsArray()
    }
}

extension VertexDescriptor: CustomStringConvertible {
    public var description: String {
        let attributesDesc = self.attributes.enumerated()
            .reduce(
                into: "",
                { result, value in
                    let shouldInsertColumn = value.offset < self.attributes.count - 1
                    let newDesc = value.element.description + (shouldInsertColumn ? "," : "")
                    result += " " + newDesc + "\n"
                }
            )
        let layoutsDesc = self.layouts.enumerated()
            .reduce(
                into: "",
                { result, value in
                    let shouldInsertColumn = value.offset < self.layouts.count - 1
                    let newDesc = value.element.description + (shouldInsertColumn ? "," : "")
                    result += " " + newDesc + "\n"
                }
            )
        return unsafe String(format: "VertexDescriptor: attributes(\n%@) layots: {\n%@}", attributesDesc, layoutsDesc)
    }
}

#if METAL
    extension VertexDescriptor {
        public init(mdlVertexDescriptor: MDLVertexDescriptor) {
            let attributes: [Attribute] = mdlVertexDescriptor.attributes.compactMap {
                guard
                    let attr = ($0 as? MDLVertexAttribute),
                    !attr.name.isEmpty,
                    attr.format != .invalid
                else {
                    return nil
                }

                return Attribute(
                    name: attr.name,
                    offset: attr.offset,
                    bufferIndex: attr.bufferIndex,
                    format: VertexFormat(vertexFormat: attr.format)
                )
            }

            let layouts: [Layout] = mdlVertexDescriptor.layouts.compactMap {
                guard let layout = ($0 as? MDLVertexBufferLayout), layout.stride > 0 else {
                    return nil
                }
                return Layout(stride: layout.stride)
            }

            self.init()

            self.attributes = VertexDescriptorAttributesArray(buffer: attributes)
            self.layouts = VertexDescriptorLayoutsArray(buffer: layouts)
        }

        public func makeMTKVertexDescriptor() throws -> MTLVertexDescriptor? {
            let descriptor = self.makeMDLVertexDescriptor()
            return try MTKMetalVertexDescriptorFromModelIOWithError(descriptor)
        }

        public func makeMDLVertexDescriptor() -> MDLVertexDescriptor {
            let descriptor = MDLVertexDescriptor()
            descriptor.attributes = NSMutableArray(array: self.attributes.buffer.map(makeMDLVertexAttribute))
            descriptor.layouts = NSMutableArray(array: self.layouts.buffer.map { MDLVertexBufferLayout(stride: $0.stride) })

            return descriptor
        }

        private func makeMDLVertexAttribute(from attribute: Attribute) -> MDLVertexAttribute {
            let mdlAttribute = MDLVertexAttribute()
            mdlAttribute.bufferIndex = attribute.bufferIndex
            mdlAttribute.offset = attribute.offset
            mdlAttribute.format = attribute.format.mdlVertexFormat
            return mdlAttribute
        }
    }

    extension VertexFormat {
        var mdlVertexFormat: MDLVertexFormat {
            switch self {
            case .uint: return .uInt
            case .float: return .float
            case .vector4: return .float4
            case .vector3: return .float3
            case .vector2: return .float2
            case .char: return .char
            case .short: return .short
            case .int: return .int
            default:
                return .invalid
            }
        }

        init(vertexFormat: MDLVertexFormat) {
            switch vertexFormat {
            case .uInt: self = .uint
            case .float: self = .float
            case .float4: self = .vector4
            case .float3: self = .vector3
            case .float2: self = .vector2
            case .char: self = .char
            case .int: self = .int
            case .short: self = .short
            default:
                self = .invalid
            }
        }
    }

    extension VertexFormat {
        var metalFormat: MTLVertexFormat {
            switch self {
            case .uint: return MTLVertexFormat.uint
            case .vector4: return .float4
            case .float: return .float
            case .vector3: return .float3
            case .vector2: return .float2
            case .short: return .short
            case .int: return .int
            case .char: return .char
            default:
                return .invalid
            }
        }
    }
#endif
