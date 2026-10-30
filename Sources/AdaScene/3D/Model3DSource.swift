import AdaAnimation
import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import Foundation

/// Portable mesh alternatives, retaining the base model's node and material ordering.
public struct Model3DSourceLOD: Codable, Equatable, Sendable {
    public var sources: [String]
    public var screenThresholds: [Float]
    public var maximumDistance: Float?
    public var fadeDistance: Float
    public var skeletonCompatible: Bool
    public var animationLOD: Bool

    public init(sources: [String] = [], screenThresholds: [Float] = [], maximumDistance: Float? = nil,
                fadeDistance: Float = 5, skeletonCompatible: Bool = false, animationLOD: Bool = false) {
        self.sources = sources
        self.screenThresholds = screenThresholds
        self.maximumDistance = maximumDistance
        self.fadeDistance = fadeDistance
        self.skeletonCompatible = skeletonCompatible
        self.animationLOD = animationLOD
    }
}

/// A portable model reference that preserves imported hierarchy, materials and animation.
/// ``Model3DPlugin`` loads the asset and creates an instance beneath the owning entity.
@Component
public struct Model3DSource: Codable, Equatable, Sendable {
    public var source: String
    public var animation: String
    public var autoplay: Bool
    public var repeats: Bool
    /// Optional authored pose graph. When present it takes precedence over the single clip.
    public var animationGraph: AnimationGraph?
    public var lod: Model3DSourceLOD?
    /// Import settings for MagicaVoxel (`.vox`) sources; ignored for other formats.
    public var voxel: VoxelImportSettings?
    /// Morph target weights by target name, applied to every mesh of the model that has a target of that name. They are the
    /// weights the instance starts with and keeps unless an animation clip animates that mesh's weights.
    public var morphWeights: [String: Float]
    /// Overrides by the model document's global material index, encoded as a decimal key.
    public var graphMaterials: [String: ShaderGraphMaterialSource] = [:]
    /// Sidecar for the derived model's UV1 atlas, never shared back into the imported material asset.
    public var lightmapSource: String = ""
    public var lightmapIntensity: Float = 1

    public init(source: String = "", animation: String = "", autoplay: Bool = false, repeats: Bool = true,
                animationGraph: AnimationGraph? = nil, lod: Model3DSourceLOD? = nil, voxel: VoxelImportSettings? = nil,
                morphWeights: [String: Float] = [:]) {
        self.morphWeights = morphWeights
        self.voxel = voxel
        self.source = source
        self.animation = animation
        self.autoplay = autoplay
        self.repeats = repeats
        self.animationGraph = animationGraph
        self.lod = lod
    }

    private enum CodingKeys: CodingKey {
        case source, animation, autoplay, repeats, animationGraph, lod, voxel, morphWeights, graphMaterials, lightmapSource, lightmapIntensity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        graphMaterials = try container.decodeIfPresent([String: ShaderGraphMaterialSource].self, forKey: .graphMaterials) ?? [:]
        lightmapSource = try container.decodeIfPresent(String.self, forKey: .lightmapSource) ?? ""
        lightmapIntensity = try container.decodeIfPresent(Float.self, forKey: .lightmapIntensity) ?? 1
        source = try container.decode(String.self, forKey: .source)
        animation = try container.decode(String.self, forKey: .animation)
        autoplay = try container.decode(Bool.self, forKey: .autoplay)
        repeats = try container.decode(Bool.self, forKey: .repeats)
        animationGraph = try container.decodeIfPresent(AnimationGraph.self, forKey: .animationGraph)
        lod = try container.decodeIfPresent(Model3DSourceLOD.self, forKey: .lod)
        voxel = try container.decodeIfPresent(VoxelImportSettings.self, forKey: .voxel)
        // Scenes written before morph targets have no weights.
        morphWeights = try container.decodeIfPresent([String: Float].self, forKey: .morphWeights) ?? [:]
    }

    /// The path the model asset is loaded from: ``source`` plus the import settings of a `.vox` file as an asset query.
    public var assetPath: String {
        guard let voxel, !voxel.isDefault, !source.isEmpty, !source.contains("#"),
            source.lowercased().hasSuffix(".vox"), !voxel.assetQuery.isEmpty
        else {
            return source
        }
        return "\(source)#\(voxel.assetQuery)"
    }

    /// Installs an already loaded asset. Used by hosts that prepare models before their first frame.
    /// An invalid clip fails before creating entities. Each call creates an independent animation player.
    @discardableResult
    public func instantiate(_ model: ModelAsset3D, alternatives: [ModelAsset3D] = [], in world: World, under owner: Entity) throws -> Entity {
        if let lod, alternatives.count != lod.sources.count {
            throw AssetError.message("Model LOD alternatives have not been loaded.")
        }
        guard animationGraph != nil || animation.isEmpty || model.animationClips.contains(where: { $0.name == animation }) else {
            throw AssetError.message("Model has no animation named '\(animation)'.")
        }
        if let animationGraph {
            guard let rig = model.animationRig else { throw AssetError.message("Model has no animation rig.") }
            try animationGraph.validate(rig: rig, clips: model.animationClips)
        }
        var graphOverrides: [Int: PBRMaterial] = [:]
        for key in graphMaterials.keys.sorted() {
            guard let index = Int(key), String(index) == key, model.materials.indices.contains(index), let source = graphMaterials[key] else {
                throw ShaderGraphDiagnostic(code: .invalidReference, nodeID: key)
            }
            graphOverrides[index] = try Self.makeGraphOverride(copying: model.materials[index], source: source)
        }
        if !lightmapSource.isEmpty {
            guard model.animationRig == nil, lod == nil else {
                throw AssetError.message("Lightmaps require a static model without skeletal animation or LOD alternatives")
            }
            let handle = try AssetsManager.loadSync(LightmapSet3D.self, at: lightmapSource)
            guard let maps = handle.asset else { throw AssetError.message("Lightmap sidecar was not loaded") }
            guard maps.modelFile.isEmpty || URL(fileURLWithPath: source).lastPathComponent == maps.modelFile else {
                throw AssetError.message("Lightmap sidecar belongs to another derived model")
            }
            for mesh in model.meshes { for modelPart in mesh.models { for part in modelPart.parts where maps.materials[part.materialIndex] != nil {
                guard part.vertexDescriptor.attributes.containsAttribute(by: MeshDescriptor.textureCoordinates1.id.name) else {
                    throw AssetError.message("Lightmapped model part has no UV1; use the baker's derived GLB")
                }
            } } }
            for (index, texture) in maps.materials {
                guard model.materials.indices.contains(index), let original = model.materials[index] as? PBRMaterial else {
                    throw AssetError.message("Lightmap references an invalid PBR material")
                }
                let material = graphOverrides[index] ?? original.makeInstance()
                material.lightmapTexture = texture
                material.lightmapIntensity = lightmapIntensity.isFinite ? max(0, min(lightmapIntensity, 16)) : 1
                graphOverrides[index] = material
            }
        }
        let root = model.instantiate(in: world)
        if !graphOverrides.isEmpty {
            var pending = [root]
            while let node = pending.popLast() {
                if var mesh = node.components[Mesh3DComponent.self] {
                    for (index, material) in graphOverrides where mesh.materials.indices.contains(index) { mesh.materials[index] = material }
                    node.components[Mesh3DComponent.self] = mesh
                }
                pending.append(contentsOf: node.children)
            }
        }
        if !morphWeights.isEmpty {
            var pending = [root]
            while let node = pending.popLast() {
                if var component = node.components[MorphWeights3DComponent.self] {
                    var changed = false
                    for (name, weight) in morphWeights where weight.isFinite {
                        if component.setWeight(weight, named: name) { changed = true }
                    }
                    if changed { node.components[MorphWeights3DComponent.self] = component }
                }
                pending.append(contentsOf: node.children)
            }
        }
        if var animationComponent = root.components[ModelAnimation3DComponent.self], animationGraph != nil || !animation.isEmpty {
            if let animationGraph {
                try animationComponent.player.play(animationGraph, transitionDuration: 0)
            } else {
                try animationComponent.player.play(animation, transitionDuration: 0)
            }
            animationComponent.player.isPlaying = autoplay
            animationComponent.player.repeats = repeats
            if lod?.animationLOD == true { animationComponent.evaluationLOD = AnimationLOD3DSettings() }
            root.components[ModelAnimation3DComponent.self] = animationComponent
        }
        if var voxelPlayback = root.components[VoxelAnimationPlayback3DComponent.self] {
            voxelPlayback.isPlaying = autoplay
            voxelPlayback.repeats = repeats
            root.components[VoxelAnimationPlayback3DComponent.self] = voxelPlayback
        }
        owner.addChild(root)
        if let lod {
            var pending = root.children
            while let node = pending.popLast() {
                if let binding = node.components[ModelNode3DComponent.self], model.nodes.indices.contains(binding.nodeIndex),
                    let meshIndex = model.nodes[binding.nodeIndex].meshIndex,
                    alternatives.allSatisfy({ $0.meshes.indices.contains(meshIndex) }) {
                    var value = MeshLOD3DComponent(alternatives: alternatives.map { $0.meshes[meshIndex] },
                                                   screenThresholds: lod.screenThresholds, maximumDistance: lod.maximumDistance,
                                                   fadeDistance: lod.fadeDistance)
                    value.skeletonCompatible = lod.skeletonCompatible
                    node.components[MeshLOD3DComponent.self] = value
                }
                pending.append(contentsOf: node.children)
            }
        }
        owner.components[Model3DSourceState.self] = .init(reference: self, rootEntityID: root.id)
        return root
    }
}

/// Runtime status of a model reference. Generated nodes are not part of the authored scene.
public struct Model3DSourceState: Component {
    public let reference: Model3DSource
    public let rootEntityID: Entity.ID?
    public let error: String?

    public init(reference: Model3DSource, rootEntityID: Entity.ID? = nil, error: String? = nil) {
        self.reference = reference
        self.rootEntityID = rootEntityID
        self.error = error
    }
}

/// Loads changed references asynchronously, applying hierarchy changes through deferred world commands.
@PlainSystem
public struct Model3DSourceSystem {
    @Query<Entity, Model3DSource> private var sources
    @Query<Entity, Model3DSourceState> private var instances
    @Commands private var commands
    // The asset cache keeps weak handles. Retaining only handle.asset drops the
    // cache key and reimports the same mesh/textures for every scene instance.
    @Local private var modelHandles: [String: AssetHandle<ModelAsset3D>] = [:]

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        var pending: [(Entity.ID, Model3DSource)] = []
        var livePaths: Set<String> = []
        sources.forEach { entity, reference in
            if !reference.source.isEmpty { livePaths.insert(reference.assetPath) }
            livePaths.formUnion(reference.lod?.sources ?? [])
            let state = entity.components[Model3DSourceState.self]
            if state?.reference != reference { pending.append((entity.id, reference)) }
        }
        for path in modelHandles.keys where !livePaths.contains(path) { modelHandles.removeValue(forKey: path) }
        instances.forEach { entity, state in
            guard entity.components[Model3DSource.self] == nil else {
                return
            }
            let id = entity.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Model3DSource.self] == nil else {
                    return
                }
                if let rootID = state.rootEntityID { world.removeEntity(rootID, recursively: true) }
                owner.components[Model3DSourceState.self] = nil
            }
        }
        for (id, reference) in pending {
            let result: Result<(ModelAsset3D?, [ModelAsset3D]), AssetError>
            do {
                let model = reference.source.isEmpty ? nil : try await loadModel(reference.assetPath)
                var alternatives: [ModelAsset3D] = []
                for source in reference.lod?.sources ?? [] {
                    guard let level = try await loadModel(source) else {
                        throw AssetError.message("Model LOD has not loaded: \(source)")
                    }
                    alternatives.append(level)
                }
                result = .success((model, alternatives))
            } catch {
                result = .failure(.message(error.localizedDescription))
            }
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Model3DSource.self] == reference,
                    owner.components[Model3DSourceState.self]?.reference != reference else { return }
                if let rootID = owner.components[Model3DSourceState.self]?.rootEntityID {
                    world.removeEntity(rootID, recursively: true)
                }
                do {
                    let (model, alternatives) = try result.get()
                    if let model {
                        try reference.instantiate(model, alternatives: alternatives, in: world, under: owner)
                    } else {
                        owner.components[Model3DSourceState.self] = .init(reference: reference)
                    }
                } catch {
                    owner.components[Model3DSourceState.self] = .init(reference: reference, error: error.localizedDescription)
                }
            }
        }
    }

    private func loadModel(_ path: String) async throws -> ModelAsset3D? {
        if let handle = modelHandles[path] { return handle.asset }
        let handle = try await AssetsManager.load(ModelAsset3D.self, at: path)
        modelHandles[path] = handle
        return handle.asset
    }
}
