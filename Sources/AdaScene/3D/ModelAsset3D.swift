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
        /// Keyed transform and mesh animation of imported voxel scenes.
        public let voxelAnimation: VoxelNodeAnimation?
        /// Morph target weights of this node's mesh instance; they replace the mesh's default weights.
        public let morphWeights: [Float]?

        public init(
            name: String?,
            transform: Transform3D,
            meshIndex: Int?,
            children: [Int],
            skinIndex: Int? = nil,
            restPose: GLTFImportResult.NodeTRS? = nil,
            voxelAnimation: VoxelNodeAnimation? = nil,
            morphWeights: [Float]? = nil
        ) {
            self.morphWeights = morphWeights
            self.voxelAnimation = voxelAnimation
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
    /// Default morph target weights of each mesh, empty for a mesh without morph targets.
    public private(set) var meshMorphWeights: [[Float]] = []
    /// Content of the source file the importer could not honor, such as glTF extensions it does not implement.
    /// Empty for formats that report nothing. The model still loads and renders without that content.
    public private(set) var importWarnings: [String] = []

    public var assetMetaInfo: AssetMetaInfo?

    /// Timeline of an imported voxel scene; `nil` when nothing in the scene is animated.
    public internal(set) var voxelTimeline: VoxelTimeline?

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

    public convenience init(from assetDecoder: any AssetDecoder) async throws {
        try await self.init(fileURL: assetDecoder.assetMeta.filePath, queryParams: assetDecoder.assetMeta.queryParams, gltfLoader: nil)
    }

    /// Constructs a glTF model using a caller-owned import policy, without changing the global loader resolver.
    /// A host can supply a restricted native loader to bound files, dependencies and decoded accessor work.
    public convenience init(gltfAt url: URL, loader: any GLTFLoader) async throws {
        guard ["glb", "gltf"].contains(url.pathExtension.lowercased()) else {
            throw AssetDecodingError.invalidAssetExtension(url.pathExtension)
        }
        try await self.init(fileURL: url, queryParams: [], gltfLoader: loader)
    }

    private init(fileURL: URL, queryParams: [AssetQuery], gltfLoader: (any GLTFLoader)?) async throws {
        if fileURL.pathExtension.lowercased() == "vox" {
            let settings = VoxelImportSettings(queryParams: queryParams)
            let contents = try await Self.loadVoxelContents(url: fileURL, options: settings.options)
            self.nodes = contents.nodes
            self.meshes = contents.meshes
            self.materials = contents.materials
            self.scenes = contents.scenes
            self.defaultScene = 0
            self.skins = []
            self.animationRig = nil
            self.animationClips = []
            self.voxelTimeline = contents.timeline
            return
        }

        if fileURL.pathExtension.lowercased() == "obj" {
            let loader = OBJLoaderResolver.shared.getLoader()
            let result = try await loader.load(url: fileURL)
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

        let loader = gltfLoader ?? GLTFLoaderResolver.shared.getLoader()
        let result = try await loader.load(url: fileURL)
        importWarnings = result.warnings
        var preparedMeshlets: MeshletSidecar?
        let sidecarURL = fileURL.appendingPathExtension("meshlets")
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: sidecarURL.path)
                guard let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(MeshletSidecar.maximumByteCount) else {
                    throw MeshletDataError.invalidSidecar
                }
                preparedMeshlets = try MeshletSidecar(data: Data(contentsOf: sidecarURL))
            } catch {
                importWarnings.append("Ignored invalid meshlet sidecar: \(sidecarURL.lastPathComponent). Original geometry is retained.")
            }
        }
        var preparedMeshletLOD: MeshletLODSidecar?
        let hierarchyURL = fileURL.appendingPathExtension("meshletlod")
        if FileManager.default.fileExists(atPath: hierarchyURL.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: hierarchyURL.path)
                guard let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(MeshletLODSidecar.maximumByteCount) else {
                    throw MeshletDataError.invalidSidecar
                }
                preparedMeshletLOD = try MeshletLODSidecar(data: Data(contentsOf: hierarchyURL))
            } catch {
                importWarnings.append("Ignored invalid meshlet LOD sidecar: \(hierarchyURL.lastPathComponent). Original geometry is retained.")
            }
        }

        guard result.skins.allSatisfy({ $0.joints.count <= Skinning3DUniforms.maximumJoints }) else {
            throw AssetError.message("A skinned mesh supports at most \(Skinning3DUniforms.maximumJoints) joints.")
        }
        skins = result.skins
        animationRig = result.skins.isEmpty && result.animations.isEmpty ? nil : try Self.makeRig(nodes: result.nodes, meshes: result.meshes)
        animationClips = try Self.makeClips(result.animations, nodes: result.nodes, meshes: result.meshes)
        let device = unsafe RenderEngine.shared.renderDevice

        let materials = try Self.makeMaterials(result)

        // 2. Convert Meshes
        var meshes: [Mesh] = []
        var incompatibleMeshletParts = 0
        var incompatibleMeshletLODParts = 0
        for (meshIndex, gltfMesh) in result.meshes.enumerated() {
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
                if descriptor.primitiveTopology == .triangleList, let preparedMeshlets {
                    do {
                        descriptor.meshlets = try preparedMeshlets.geometry(meshIndex: meshIndex, partIndex: index,
                            positions: descriptor.positions.elements, indices: descriptor.indicies)
                    } catch {
                        incompatibleMeshletParts += 1
                    }
                }
                if descriptor.primitiveTopology == .triangleList, let preparedMeshletLOD {
                    do {
                        descriptor.meshletLOD = try preparedMeshletLOD.geometry(meshIndex: meshIndex, partIndex: index,
                            positions: descriptor.positions.elements, indices: descriptor.indicies)
                    } catch {
                        incompatibleMeshletLODParts += 1
                    }
                }

                var part = Mesh.Part(
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
                if !primitive.morphTargets.isEmpty {
                    guard let morph = MorphTargetSet(
                        positionDeltas: primitive.morphTargets.map(\.positionDeltas),
                        normalDeltas: primitive.morphTargets.map(\.normalDeltas),
                        tangentDeltas: primitive.morphTargets.map(\.tangentDeltas),
                        vertexCount: descriptor.positions.count,
                        targetNames: gltfMesh.targetNames
                    ) else {
                        throw AssetError.message("The \(primitive.morphTargets.count) morph targets of mesh \"\(gltfMesh.name ?? "")\" do not fit the delta texture (at most \(MorphTargetSet.textureWidth * MorphTargetSet.maximumTextureRows) texels of vertices x targets x attributes).")
                    }
                    part.morphTargets = morph
                }
                parts.append(part)
            }

            meshes.append(Mesh(models: [Mesh.Model(name: gltfMesh.name ?? "", parts: parts)]))
            meshMorphWeights.append(gltfMesh.defaultWeights)
        }
        if incompatibleMeshletParts > 0 {
            importWarnings.append("Ignored \(incompatibleMeshletParts) stale or invalid meshlet parts. Original geometry is retained.")
        }
        if incompatibleMeshletLODParts > 0 {
            importWarnings.append("Ignored \(incompatibleMeshletLODParts) stale or invalid meshlet LOD parts. Exact source geometry is retained.")
        }

        nodes = result.nodes.map {
            Node(name: $0.name, transform: $0.transform, meshIndex: $0.meshIndex, children: $0.children, skinIndex: $0.skinIndex, restPose: $0.restPose, morphWeights: $0.weights)
        }
        self.meshes = meshes
        self.materials = materials
        scenes = result.scenes
        defaultScene = result.defaultScene
    }

    @discardableResult
    public func instantiate(in world: World) -> Entity {
        let rootEntity = world.spawn(assetName)
        rootEntity.components[Transform.self] = Transform()
        if let voxelTimeline {
            rootEntity.components[VoxelAnimationPlayback3DComponent.self] = VoxelAnimationPlayback3DComponent(
                framesPerSecond: voxelTimeline.framesPerSecond,
                frameCount: voxelTimeline.frameCount
            )
        }
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

        if let animation = node.voxelAnimation {
            if !animation.transformKeys.isEmpty {
                entity.components[VoxelTransformAnimation3DComponent.self] = VoxelTransformAnimation3DComponent(
                    modelRoot: modelRoot.id,
                    animation: animation
                )
            }
            if !animation.shapeKeys.isEmpty {
                var shapeMeshes: [Int: Mesh] = [:]
                for key in animation.shapeKeys where meshes.indices.contains(key.meshIndex) {
                    shapeMeshes[key.meshIndex] = meshes[key.meshIndex]
                }
                entity.components[VoxelShapeAnimation3DComponent.self] = VoxelShapeAnimation3DComponent(
                    modelRoot: modelRoot.id,
                    animation: animation,
                    meshes: shapeMeshes
                )
            }
        }

        if let meshIndex = node.meshIndex {
            let mesh = meshes[meshIndex]
            entity.components[Mesh3DComponent.self] = Mesh3DComponent(mesh: mesh, materials: materials)
            if mesh.hasMorphTargets {
                let defaults = meshMorphWeights.indices.contains(meshIndex) ? meshMorphWeights[meshIndex] : []
                let weights = node.morphWeights ?? (defaults.count == mesh.morphTargetCount ? defaults : [Float](repeating: 0, count: mesh.morphTargetCount))
                entity.components[MorphWeights3DComponent.self] = MorphWeights3DComponent(weights: weights, targetNames: mesh.morphTargetNames)
            }
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
        ["gltf", "glb", "obj", "vox"]
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
