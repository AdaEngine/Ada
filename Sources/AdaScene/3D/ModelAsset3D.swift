//
//  ModelAsset3D.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Foundation
import Math

/// An asset that represents a 3D model.
public final class ModelAsset3D: Asset, @unchecked Sendable {
    public struct Node: Sendable {
        public let name: String?
        public let transform: Transform3D
        public let meshIndex: Int?
        public let children: [Int]

        public init(name: String?, transform: Transform3D, meshIndex: Int?, children: [Int]) {
            self.name = name
            self.transform = transform
            self.meshIndex = meshIndex
            self.children = children
        }
    }

    public let nodes: [Node]
    public let meshes: [Mesh]
    public let materials: [Material]
    public let scenes: [[Int]]
    public let defaultScene: Int?

    public var assetMetaInfo: AssetMetaInfo?

    public init(nodes: [Node], meshes: [Mesh], materials: [Material], scenes: [[Int]], defaultScene: Int?) {
        self.nodes = nodes
        self.meshes = meshes
        self.materials = materials
        self.scenes = scenes
        self.defaultScene = defaultScene
    }

    public init(from assetDecoder: any AssetDecoder) async throws {
        if assetDecoder.assetMeta.filePath.pathExtension.lowercased() == "obj" {
            let loader = OBJLoaderResolver.shared.getLoader()
            let result = try await loader.load(url: assetDecoder.assetMeta.filePath)
            let device = unsafe RenderEngine.shared.renderDevice

            self.materials = result.materials.map { _ in PBRMaterial() }
            self.meshes = result.meshes.map { mesh in
                let parts = mesh.primitives.enumerated()
                    .map { index, primitive in
                        var descriptor = MeshDescriptor(name: "Primitive \(index)")
                        descriptor.positions = MeshBuffer(primitive.positions)
                        descriptor.normals = primitive.normals.map(MeshBuffer.init)
                        descriptor.textureCoordinates = primitive.textureCoordinates.map(MeshBuffer.init)
                        descriptor.indicies = primitive.indices

                        return Mesh.Part(
                            id: index,
                            materialIndex: primitive.materialIndex,
                            primitiveTopology: .triangleList,
                            isUInt32: true,
                            meshDescriptor: descriptor,
                            vertexDescriptor: descriptor.getMeshVertexBufferDescriptor(),
                            indexBuffer: descriptor.getIndexBuffer(renderDevice: device),
                            indexCount: descriptor.indicies.count,
                            vertexBuffer: descriptor.getVertexBuffer(renderDevice: device)
                        )
                    }
                return Mesh(models: [Mesh.Model(name: mesh.name, parts: parts)])
            }
            self.nodes = result.meshes.indices.map { index in
                Node(name: result.meshes[index].name, transform: .identity, meshIndex: index, children: [])
            }
            self.scenes = [Array(result.meshes.indices)]
            self.defaultScene = 0
            return
        }

        let loader = GLTFLoaderResolver.shared.getLoader()
        let result = try await loader.load(url: assetDecoder.assetMeta.filePath)

        let device = unsafe RenderEngine.shared.renderDevice

        // 1. Convert Materials
        var materials: [Material] = []
        for gltfMaterial in result.materials {
            let material = PBRMaterial()
            material.baseColorFactor = gltfMaterial.baseColorFactor
            material.metallicFactor = gltfMaterial.metallicFactor
            material.roughnessFactor = gltfMaterial.roughnessFactor

            if let textureIndex = gltfMaterial.baseColorTextureIndex {
                let gltfTexture = result.textures[textureIndex]
                let gltfImage = result.images[gltfTexture.source]

                if let data = gltfImage.data {
                    if let image = try? Image.decode(from: data) {
                        material.baseColorTexture = Texture2D(image: image)
                    }
                }
            }

            if let textureIndex = gltfMaterial.metallicRoughnessTextureIndex {
                let gltfTexture = result.textures[textureIndex]
                let gltfImage = result.images[gltfTexture.source]

                if let data = gltfImage.data {
                    if let image = try? Image.decode(from: data) {
                        material.metallicRoughnessTexture = Texture2D(image: image)
                    }
                }
            }

            if let textureIndex = gltfMaterial.normalTextureIndex {
                let gltfTexture = result.textures[textureIndex]
                let gltfImage = result.images[gltfTexture.source]

                if let data = gltfImage.data {
                    if let image = try? Image.decode(from: data) {
                        material.normalTexture = Texture2D(image: image)
                    }
                }
            }

            materials.append(material)
        }
        if materials.isEmpty {
            materials.append(PBRMaterial())
        }

        // 2. Convert Meshes
        var meshes: [Mesh] = []
        for gltfMesh in result.meshes {
            var parts: [Mesh.Part] = []

            for (index, primitive) in gltfMesh.primitives.enumerated() {
                var descriptor = MeshDescriptor(name: "Primitive \(index)")

                if let positions = primitive.attributes[.position] {
                    descriptor.positions = MeshBuffer(positions.vector3Values())
                }

                if let normals = primitive.attributes[.normal] {
                    descriptor.normals = MeshBuffer(normals.vector3Values())
                }

                if let textureCoordinates = primitive.attributes[.texCoord(0)] {
                    descriptor.textureCoordinates = MeshBuffer(textureCoordinates.vector2Values())
                }

                if let tangents = primitive.attributes[.tangent] {
                    descriptor.tangents = MeshBuffer(tangents.vector4Values())
                }

                if let colors = primitive.attributes[.color(0)] {
                    if colors.componentCount == 3 {
                        descriptor.colors = MeshBuffer(
                            colors.vector3Values()
                                .map {
                                    Color(red: $0.x, green: $0.y, blue: $0.z)
                                }
                        )
                    } else if colors.componentCount == 4 {
                        descriptor.colors = MeshBuffer(colors.vector4Values().map(Color.init))
                    }
                }

                let sourceIndices = primitive.indices ?? Array(0..<UInt32(descriptor.positions.count))
                let converted = primitive.convertTopology(indices: sourceIndices)
                descriptor.indicies = converted.indices
                descriptor.primitiveTopology = converted.topology

                let part = Mesh.Part(
                    id: index,
                    materialIndex: primitive.materialIndex ?? 0,
                    primitiveTopology: descriptor.primitiveTopology,
                    isUInt32: true,
                    meshDescriptor: descriptor,
                    vertexDescriptor: descriptor.getMeshVertexBufferDescriptor(),
                    indexBuffer: descriptor.getIndexBuffer(renderDevice: device),
                    indexCount: descriptor.indicies.count,
                    vertexBuffer: descriptor.getVertexBuffer(renderDevice: device)
                )
                parts.append(part)
            }

            meshes.append(Mesh(models: [Mesh.Model(name: gltfMesh.name ?? "", parts: parts)]))
        }

        self.nodes = result.nodes.map { Node(name: $0.name, transform: $0.transform, meshIndex: $0.meshIndex, children: $0.children) }
        self.meshes = meshes
        self.materials = materials
        self.scenes = result.scenes
        self.defaultScene = result.defaultScene
    }

    @discardableResult
    public func instantiate(in world: World) -> Entity {
        let rootEntity = world.spawn(self.assetName)

        let sceneIndex = self.defaultScene ?? 0
        if self.scenes.indices.contains(sceneIndex) {
            let nodeIndices = self.scenes[sceneIndex]
            for nodeIndex in nodeIndices {
                self.instantiateNode(nodeIndex, parent: rootEntity, in: world)
            }
        }

        return rootEntity
    }

    private func instantiateNode(_ nodeIndex: Int, parent: Entity, in world: World) {
        let node = self.nodes[nodeIndex]
        let entity = world.spawn(node.name ?? "Node \(nodeIndex)")
        entity.components[Transform.self] = Transform(matrix: node.transform)

        if let meshIndex = node.meshIndex {
            let mesh = self.meshes[meshIndex]
            entity.components[Mesh3DComponent.self] = Mesh3DComponent(mesh: mesh, materials: self.materials)
        }

        parent.addChild(entity)

        for childIndex in node.children {
            self.instantiateNode(childIndex, parent: entity, in: world)
        }
    }

    public func encodeContents(with _: any AssetEncoder) async throws {
        throw AssetError.message("ModelAsset3D encoding is unsupported.")
    }

    public static func extensions() -> [String] {
        return ["gltf", "glb", "obj"]
    }
}

extension GLTFImportResult.Primitive {
    func convertTopology(indices: [UInt32]) -> (indices: [UInt32], topology: Mesh.PrimitiveTopology) {
        switch mode {
        case .points:
            return (indices, .points)
        case .lines:
            return (indices, .lineList)
        case .lineLoop:
            guard indices.count >= 2 else {
                return ([], .lineList)
            }
            var lineIndices: [UInt32] = []
            lineIndices.reserveCapacity(indices.count * 2)
            for index in indices.indices {
                lineIndices.append(indices[index])
                lineIndices.append(indices[(index + 1) % indices.count])
            }
            return (lineIndices, .lineList)
        case .lineStrip:
            return (indices, .lineStrip)
        case .triangles:
            return (indices, .triangleList)
        case .triangleStrip:
            return (indices, .triangleStrip)
        case .triangleFan:
            guard indices.count >= 3 else {
                return ([], .triangleList)
            }
            var triangleIndices: [UInt32] = []
            triangleIndices.reserveCapacity((indices.count - 2) * 3)
            for index in 1..<(indices.count - 1) {
                triangleIndices.append(indices[0])
                triangleIndices.append(indices[index])
                triangleIndices.append(indices[index + 1])
            }
            return (triangleIndices, .triangleList)
        }
    }
}
