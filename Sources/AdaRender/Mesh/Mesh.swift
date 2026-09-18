//
//  Mesh.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/1/21.
//

import AdaAssets
import AdaUtils
import Math

/// A high-level representation of a collection of vertices and edges that define a shape.
public struct Mesh: Asset, Sendable {
    @_spi(Internal)
    public let models: [Self.Model]

    @_spi(Internal)
    public init(models: [Model]) {
        self.models = models
        self.bounds = Self.computeAABB(models: models) ?? .empty
    }

    enum CodingKeys: String, CodingKey {
        case vertexDescriptor
    }

    /// A box that bounds the mesh.
    public let bounds: AABB

    // MARK: - Resource

    public var assetMetaInfo: AssetMetaInfo?

    public init(from _: AssetDecoder) throws {
        fatalErrorMethodNotImplemented()
    }

    public func encodeContents(with _: AssetEncoder) throws {
        fatalErrorMethodNotImplemented()
    }

    public static func extensions() -> [String] {
        ["mesh"]
    }
}

extension Mesh {
    /// A part of a model consisting of a single material.
    public struct Part: Identifiable, Sendable {
        /// The stable identity of the entity associated with this instance.
        public let id: Int

        /// Material index for the part.
        public var materialIndex: Int

        /// A mesh topology
        public let primitiveTopology: Mesh.PrimitiveTopology

        public let isUInt32: Bool

        /// Descriptors for the buffers.
        public let meshDescriptor: MeshDescriptor

        @_spi(Internal)
        public internal(set) var vertexDescriptor: VertexDescriptor

        /// Index buffer for triangles.
        public var indexBuffer: IndexBuffer
        public var indexCount: Int
        public var vertexBuffer: VertexBuffer

        @_spi(Internal)
        public init(
            id: Int,
            materialIndex: Int,
            primitiveTopology: Mesh.PrimitiveTopology,
            isUInt32: Bool,
            meshDescriptor: MeshDescriptor,
            vertexDescriptor: VertexDescriptor,
            indexBuffer: IndexBuffer,
            indexCount: Int,
            vertexBuffer: VertexBuffer
        ) {
            self.id = id
            self.materialIndex = materialIndex
            self.primitiveTopology = primitiveTopology
            self.isUInt32 = isUInt32
            self.meshDescriptor = meshDescriptor
            self.vertexDescriptor = vertexDescriptor
            self.indexBuffer = indexBuffer
            self.indexCount = indexCount
            self.vertexBuffer = vertexBuffer
        }
    }

    /// A model consists of a list of parts.
    public struct Model: Sendable {
        /// The name of model
        public var name: String

        /// Table of parts composing this mesh.
        public var parts: [Part] = []

        @_spi(Internal)
        public init(name: String, parts: [Part]) {
            self.name = name
            self.parts = parts
        }
    }
}

extension Mesh {
    /// Create a mesh resource from a list of mesh descriptors.
    public static func generate(from meshDescriptors: [MeshDescriptor], renderDevice: RenderDevice) -> Mesh {
        var parts = [Part]()

        for (index, meshDescriptor) in meshDescriptors.enumerated() {
            let part = Part(
                id: index,
                materialIndex: 0,
                primitiveTopology: meshDescriptor.primitiveTopology,
                isUInt32: true,
                meshDescriptor: meshDescriptor,
                vertexDescriptor: meshDescriptor.getMeshVertexBufferDescriptor(),
                indexBuffer: meshDescriptor.getIndexBuffer(renderDevice: renderDevice),
                indexCount: meshDescriptor.indicies.count,
                vertexBuffer: meshDescriptor.getVertexBuffer(renderDevice: renderDevice)
            )

            parts.append(part)
        }

        let model = Model(name: "", parts: parts)
        return Mesh(models: [model])
    }
}

extension Mesh {
    /// Compute the Axis-Aligned Bounding Box of the mesh vertices in model space
    private static func computeAABB(models: [Mesh.Model]) -> AABB? {
        let floatMin = -Float.greatestFiniteMagnitude

        var minimum: Vector3 = Vector3(.greatestFiniteMagnitude)
        var maximum: Vector3 = Vector3(floatMin)

        for model in models {
            for part in model.parts {
                for position in part.meshDescriptor.positions {
                    minimum = min(minimum, position)
                    maximum = max(maximum, position)
                }
            }
        }

        if minimum.x != .greatestFiniteMagnitude && minimum.y != .greatestFiniteMagnitude
            && minimum.z != .greatestFiniteMagnitude && maximum.x != floatMin
            && maximum.y != floatMin && maximum.z != floatMin {
            return AABB(min: minimum, max: maximum)
        }

        return nil
    }
}
