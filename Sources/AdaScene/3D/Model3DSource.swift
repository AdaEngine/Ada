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
    /// Project-owned `.animlib` resources. Authored graph clips use their qualified stable runtime names.
    public var animationLibraries: [String]
    /// Optional reusable `.animmod` stack and instance-local stable scene target bindings.
    public var animationModifiers: String?
    public var modifierBindings: [String: AnimationIKBinding3D]
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
                morphWeights: [String: Float] = [:], animationLibraries: [String] = [], animationModifiers: String? = nil,
                modifierBindings: [String: AnimationIKBinding3D] = [:]) {
        self.animationModifiers = animationModifiers
        self.modifierBindings = modifierBindings
        self.animationLibraries = animationLibraries
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
        case source, animation, autoplay, repeats, animationGraph, animationLibraries, animationModifiers, modifierBindings
        case lod, voxel, morphWeights, graphMaterials, lightmapSource, lightmapIntensity
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
        animationLibraries = try container.decodeIfPresent([String].self, forKey: .animationLibraries) ?? []
        animationModifiers = try container.decodeIfPresent(String.self, forKey: .animationModifiers)
        modifierBindings = try container.decodeIfPresent([String: AnimationIKBinding3D].self, forKey: .modifierBindings) ?? [:]
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(animation, forKey: .animation)
        try container.encode(autoplay, forKey: .autoplay)
        try container.encode(repeats, forKey: .repeats)
        try container.encodeIfPresent(animationGraph, forKey: .animationGraph)
        try container.encode(animationLibraries, forKey: .animationLibraries)
        try container.encodeIfPresent(animationModifiers, forKey: .animationModifiers)
        if !modifierBindings.isEmpty { try container.encode(modifierBindings, forKey: .modifierBindings) }
        try container.encodeIfPresent(lod, forKey: .lod)
        try container.encodeIfPresent(voxel, forKey: .voxel)
        try container.encode(morphWeights, forKey: .morphWeights)
        try container.encode(graphMaterials, forKey: .graphMaterials)
        try container.encode(lightmapSource, forKey: .lightmapSource)
        try container.encode(lightmapIntensity, forKey: .lightmapIntensity)
    }

    /// Validates the complete imported/authored clip set and graph without allocating runtime entities.
    /// Editor binding uses the same checks as scene instantiation.
    public func resolvedAnimationClips(importedClips: [SkeletalAnimationClip], rig: SkeletalRig?, libraries: [AnimationLibrary]) throws -> [SkeletalAnimationClip] {
        guard libraries.count == animationLibraries.count else { throw AssetError.message("Animation libraries have not been loaded.") }
        var clips = importedClips
        var libraryIDs: Set<String> = []
        for library in libraries {
            guard let rig, libraryIDs.insert(library.id).inserted else {
                throw AssetError.message("Animation libraries need a rig and unique library IDs.")
            }
            let compiled = try library.compiledClips(for: rig)
            guard !compiled.contains(where: { authored in clips.contains { $0.name == authored.name } }) else {
                throw AssetError.message("An authored animation reference conflicts with an existing clip.")
            }
            clips.append(contentsOf: compiled)
        }
        guard animationGraph != nil || animation.isEmpty || clips.contains(where: { $0.name == animation }) else {
            throw AssetError.message("Model has no animation named '\(animation)'.")
        }
        if let animationGraph {
            guard let rig else { throw AssetError.message("Model has no animation rig.") }
            try animationGraph.validate(rig: rig, clips: clips)
        }
        return clips
    }

    /// Installs an already loaded asset. An invalid animation fails before creating entities.
    @discardableResult
    public func instantiate(_ model: ModelAsset3D, alternatives: [ModelAsset3D] = [], libraries: [AnimationLibrary] = [], modifiers: AnimationModifierStack? = nil,
                            preloadedLightmap: LightmapSet3D? = nil, in world: World, under owner: Entity) throws -> Entity {
        let clips = try resolvedAnimationClips(importedClips: model.animationClips, rig: model.animationRig, libraries: libraries)
        try validateModifiers(modifiers, rig: model.animationRig)
        if let lod, alternatives.count != lod.sources.count {
            throw AssetError.message("Model LOD alternatives have not been loaded.")
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
            let maps: LightmapSet3D
            if let preloadedLightmap {
                maps = preloadedLightmap
            } else {
                #if WASM
                    throw AssetError.message("Load the lightmap sidecar asynchronously before instantiating a Web model")
                #else
                    let handle = try AssetsManager.loadSync(LightmapSet3D.self, at: lightmapSource)
                    guard let loaded = handle.asset else { throw AssetError.message("Lightmap sidecar was not loaded") }
                    maps = loaded
                #endif
            }
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
        if !libraries.isEmpty, let rig = model.animationRig {
            root.components[ModelAnimation3DComponent.self] = ModelAnimation3DComponent(player: try SkeletalAnimationPlayer(rig: rig, clips: clips))
        }
        if let modifiers, var animation = root.components[ModelAnimation3DComponent.self] {
            try animation.player.setPoseModifiers(modifiers.modifiers, binding: modifiers.binding)
            animation.modifierBindings = modifierBindings
            animation.modifierNamespace = owner.components[AnimationSceneIdentity3D.self]?.namespace ?? ""
            root.components[ModelAnimation3DComponent.self] = animation
        }
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

    /// Checks reusable configuration and scene overrides before a replacement creates any entities.
    public func validateModifiers(_ stack: AnimationModifierStack?, rig: SkeletalRig?) throws {
        guard animationModifiers != nil || stack == nil else { throw AssetError.message("Unexpected animation modifier resource.") }
        guard let reference = animationModifiers else {
            guard modifierBindings.isEmpty else { throw AssetError.message("Modifier bindings require an animation modifier resource.") }
            return
        }
        guard !reference.isEmpty, reference.utf8.count <= 4_096, let stack, let rig else {
            throw AssetError.message("Animation modifier resource or rig has not loaded.")
        }
        try stack.validate()
        guard stack.binding.isCompatible(with: rig) else { throw AnimationPoseModifierError.incompatibleRig }
        let ids = Set(stack.modifiers.map(\.id))
        guard modifierBindings.count <= 32, modifierBindings.keys.allSatisfy({ ids.contains($0) }) else {
            throw AssetError.message("Scene modifier bindings must reference modifiers in the loaded stack.")
        }
        for binding in modifierBindings.values { try binding.validate() }
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
    @Local private var libraryHandles: [String: AssetHandle<AnimationLibraryResource>] = [:]
    @Local private var modifierHandles: [String: AssetHandle<AnimationModifierResource>] = [:]

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        var pending: [(Entity.ID, Model3DSource)] = []
        var livePaths: Set<String> = []
        var liveLibraries: Set<String> = []
        var liveModifiers: Set<String> = []
        sources.forEach { entity, reference in
            if !reference.source.isEmpty { livePaths.insert(reference.assetPath) }
            livePaths.formUnion(reference.lod?.sources ?? [])
            liveLibraries.formUnion(reference.animationLibraries)
            if let path = reference.animationModifiers { liveModifiers.insert(path) }
            let state = entity.components[Model3DSourceState.self]
            if state?.reference != reference { pending.append((entity.id, reference)) }
        }
        for path in modelHandles.keys where !livePaths.contains(path) { modelHandles.removeValue(forKey: path) }
        for path in libraryHandles.keys where !liveLibraries.contains(path) { libraryHandles.removeValue(forKey: path) }
        for path in modifierHandles.keys where !liveModifiers.contains(path) { modifierHandles.removeValue(forKey: path) }
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
            let result: Result<(ModelAsset3D?, [ModelAsset3D], [AnimationLibrary], AnimationModifierStack?, LightmapSet3D?), AssetError>
            do {
                let model = reference.source.isEmpty ? nil : try await loadModel(reference.assetPath)
                var alternatives: [ModelAsset3D] = []
                for source in reference.lod?.sources ?? [] {
                    guard let level = try await loadModel(source) else {
                        throw AssetError.message("Model LOD has not loaded: \(source)")
                    }
                    alternatives.append(level)
                }
                var libraries: [AnimationLibrary] = []
                for path in reference.animationLibraries {
                    let handle: AssetHandle<AnimationLibraryResource>
                    if let cached = libraryHandles[path] { handle = cached }
                    else { handle = try await AssetsManager.load(AnimationLibraryResource.self, at: path) }
                    guard let library = handle.asset?.library else { throw AssetError.message("Animation library has not loaded: \(path)") }
                    libraryHandles[path] = handle
                    libraries.append(library)
                }
                var modifiers: AnimationModifierStack?
                if let path = reference.animationModifiers {
                    let handle: AssetHandle<AnimationModifierResource>
                    if let cached = modifierHandles[path] { handle = cached }
                    else { handle = try await AssetsManager.load(AnimationModifierResource.self, at: path) }
                    guard let stack = handle.asset?.stack else { throw AssetError.message("Animation modifiers have not loaded: \(path)") }
                    modifierHandles[path] = handle
                    modifiers = stack
                }
                let maps: LightmapSet3D?
                if model != nil, !reference.lightmapSource.isEmpty {
                    let handle = try await AssetsManager.load(LightmapSet3D.self, at: reference.lightmapSource)
                    guard let loaded = handle.asset else { throw AssetError.message("Lightmap sidecar was not loaded") }
                    maps = loaded
                } else {
                    maps = nil
                }
                result = .success((model, alternatives, libraries, modifiers, maps))
            } catch {
                result = .failure(.message(error.localizedDescription))
            }
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Model3DSource.self] == reference,
                    owner.components[Model3DSourceState.self]?.reference != reference else { return }
                let previousRoot = owner.components[Model3DSourceState.self]?.rootEntityID
                do {
                    let (model, alternatives, libraries, modifiers, maps) = try result.get()
                    if let model {
                        try reference.instantiate(model, alternatives: alternatives, libraries: libraries, modifiers: modifiers, preloadedLightmap: maps, in: world, under: owner)
                    } else {
                        owner.components[Model3DSourceState.self] = .init(reference: reference)
                    }
                    if let previousRoot { world.removeEntity(previousRoot, recursively: true) }
                } catch {
                    owner.components[Model3DSourceState.self] = .init(reference: reference, rootEntityID: previousRoot, error: error.localizedDescription)
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
