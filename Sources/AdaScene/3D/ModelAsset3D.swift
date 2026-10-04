//
//  ModelAsset3D.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaAnimation
import AdaAssets
import AdaCorePipelines
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
        public let skinIndex: Int?
        public let restPose: GLTFImportResult.NodeTRS?

        public init(name: String?, transform: Transform3D, meshIndex: Int?, children: [Int], skinIndex: Int? = nil, restPose: GLTFImportResult.NodeTRS? = nil) {
            self.name = name
            self.transform = transform
            self.meshIndex = meshIndex
            self.children = children
            self.skinIndex = skinIndex
            self.restPose = restPose
        }
    }

    public let nodes: [Node]
    public let meshes: [Mesh]
    public let materials: [Material]
    public let scenes: [[Int]]
    public let defaultScene: Int?
    public let skins: [GLTFImportResult.Skin]
    public let animationRig: SkeletalRig?
    public let animationClips: [SkeletalAnimationClip]

    public var assetMetaInfo: AssetMetaInfo?

    public init(
        nodes: [Node],
        meshes: [Mesh],
        materials: [Material],
        scenes: [[Int]],
        defaultScene: Int?,
        skins: [GLTFImportResult.Skin] = [],
        animationRig: SkeletalRig? = nil,
        animationClips: [SkeletalAnimationClip] = []
    ) {
        self.nodes = nodes
        self.meshes = meshes
        self.materials = materials
        self.scenes = scenes
        self.defaultScene = defaultScene
        self.skins = skins
        self.animationRig = animationRig
        self.animationClips = animationClips
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
            nodes = result.meshes.indices.map { index in
                Node(name: result.meshes[index].name, transform: .identity, meshIndex: index, children: [])
            }
            scenes = [Array(result.meshes.indices)]
            defaultScene = 0
            skins = []
            animationRig = nil
            animationClips = []
            return
        }

        let loader = GLTFLoaderResolver.shared.getLoader()
        let result = try await loader.load(url: assetDecoder.assetMeta.filePath)

        guard result.skins.allSatisfy({ $0.joints.count <= Skinning3DUniforms.maximumJoints }) else {
            throw AssetError.message("A skinned mesh supports at most \(Skinning3DUniforms.maximumJoints) joints.")
        }
        skins = result.skins
        animationRig = result.skins.isEmpty && result.animations.isEmpty ? nil : try Self.makeRig(nodes: result.nodes)
        animationClips = try Self.makeClips(result.animations)
        let device = unsafe RenderEngine.shared.renderDevice

        let materials = try Self.makeMaterials(result)

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

                if let coordinates = primitive.attributes[.texCoord(1)] {
                    descriptor[MeshDescriptor.textureCoordinates1] = MeshBuffer(coordinates.vector2Values())
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

                if let skinning = primitive.skinning {
                    descriptor[MeshDescriptor.jointIndices] = MeshBuffer(skinning.jointIndices.map { joints in
                        Vector4(Float(joints.x), Float(joints.y), Float(joints.z), Float(joints.w))
                    })
                    descriptor[MeshDescriptor.jointWeights] = MeshBuffer(skinning.weights)
                }

                let sourceIndices = primitive.indices ?? Array(0 ..< UInt32(descriptor.positions.count))
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

        nodes = result.nodes.map { Node(name: $0.name, transform: $0.transform, meshIndex: $0.meshIndex, children: $0.children, skinIndex: $0.skinIndex, restPose: $0.restPose) }
        self.meshes = meshes
        self.materials = materials
        scenes = result.scenes
        defaultScene = result.defaultScene
    }

    @discardableResult
    public func instantiate(in world: World) -> Entity {
        let rootEntity = world.spawn(assetName)
        rootEntity.components[Transform.self] = Transform()
        if let animationRig {
            do {
                let player = try SkeletalAnimationPlayer(rig: animationRig, clips: animationClips)
                rootEntity.components[ModelAnimation3DComponent.self] = ModelAnimation3DComponent(player: player)
            } catch {
                assertionFailure("Invalid model animation rig: \(error)")
            }
        }

        let sceneIndex = defaultScene ?? 0
        if scenes.indices.contains(sceneIndex) {
            let nodeIndices = scenes[sceneIndex]
            for nodeIndex in nodeIndices {
                instantiateNode(nodeIndex, parent: rootEntity, modelRoot: rootEntity, in: world)
            }
        }

        return rootEntity
    }

    private func instantiateNode(_ nodeIndex: Int, parent: Entity, modelRoot: Entity, in world: World) {
        let node = nodes[nodeIndex]
        let entity = world.spawn(node.name ?? "Node \(nodeIndex)")
        if let pose = animationRig?.nodes[nodeIndex].restPose {
            entity.components[Transform.self] = Transform(rotation: pose.rotation, scale: pose.scale, position: pose.translation)
        } else if let pose = node.restPose {
            entity.components[Transform.self] = Transform(rotation: pose.rotation, scale: pose.scale, position: pose.translation)
        } else {
            entity.components[Transform.self] = Transform(matrix: node.transform)
        }
        if animationRig != nil {
            entity.components[ModelNode3DComponent.self] = ModelNode3DComponent(modelRoot: modelRoot.id, nodeIndex: nodeIndex)
        }

        if let meshIndex = node.meshIndex {
            let mesh = meshes[meshIndex]
            entity.components[Mesh3DComponent.self] = Mesh3DComponent(mesh: mesh, materials: materials)
            if let skinIndex = node.skinIndex, skins.indices.contains(skinIndex),
               let animation = modelRoot.components[ModelAnimation3DComponent.self] {
                var binding = SkinnedMesh3DComponent(modelRoot: modelRoot.id, meshNodeIndex: nodeIndex, skin: skins[skinIndex])
                binding.updateMatrices(using: animation.player)
                entity.components[SkinnedMesh3DComponent.self] = binding
            }
        }

        parent.addChild(entity)

        for childIndex in node.children {
            instantiateNode(childIndex, parent: entity, modelRoot: modelRoot, in: world)
        }
    }

    public func encodeContents(with _: any AssetEncoder) async throws {
        throw AssetError.message("ModelAsset3D encoding is unsupported.")
    }

    public static func extensions() -> [String] {
        ["gltf", "glb", "obj"]
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
            for index in 1 ..< (indices.count - 1) {
                triangleIndices.append(indices[0])
                triangleIndices.append(indices[index])
                triangleIndices.append(indices[index + 1])
            }
            return (triangleIndices, .triangleList)
        }
    }
}
