@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Observation

@Observable
@MainActor
final class EditorModelAssetPreviewModel {
    var asset: ModelAsset3D?
    var previewLighting: AssetHandle<ImageBasedLighting3D>?
    var error: String?
    var isLoading = true
    var selectedAnimation = "Rest pose" { didSet { updatePlayback() } }
    var showsBones = false
    var selectedNodeIndices: Set<Int> = []
    var playbackSpeed: Double = 1 { didSet { updatePlayback() } }
    @ObservationIgnored var bonePress: Point?
    @ObservationIgnored var boneMoved = false
    @ObservationIgnored var onSelectBone: ((Int, Bool) -> Void)?
    @ObservationIgnored var onModifierInput: ((any InputEvent, EditorModelPreviewCamera) -> Bool)?
    var selectedPoseModifierID: String?
    var playsAnimation = true { didSet { updatePlayback() } }
    var animationGraph: AnimationGraph? { didSet { updatePlayback() } }
    var animationRepeats = true { didSet { updatePlayback() } }
    var graphEventLog: [String] = []
    var modifierDiagnostics: [AnimationPoseModifierDiagnostic] = []
    /// Morph target weights by name that the preview shows; every target the entity has is set to its entry, so a target removed from
    /// the map needs its default put back by the caller.
    var morphWeights: [String: Float] = [:] { didSet { applyMorphWeights() } }
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var normalizationCache: (ObjectIdentifier, Transform, AABB)?
    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private var animationRoot: Entity.ID?
    @ObservationIgnored private var voxelRoot: Entity.ID?
    @ObservationIgnored private var authoredClips: [SkeletalAnimationClip] = []
    @ObservationIgnored private var libraryGeneration: UInt64 = 0
    @ObservationIgnored private var appliedLibraryGeneration: UInt64?
    @ObservationIgnored private var pendingSeekTime: Double?
    @ObservationIgnored private var modifierStack: AnimationModifierStack?
    @ObservationIgnored private var modifierNodeIndices: [String: Int] = [:]

    func modifierNodeIndex(_ id: String) -> Int? { modifierNodeIndices[id] }

    func installPoseModifiers(_ stack: AnimationModifierStack?) throws {
        if let stack {
            try stack.validate()
            guard let rig = asset?.animationRig, stack.binding.isCompatible(with: rig) else { throw AnimationPoseModifierError.incompatibleRig }
        }
        modifierStack = stack
        modifierNodeIndices = stack.map { Dictionary(uniqueKeysWithValues: $0.binding.nodes.enumerated().map { ($0.element.id, $0.offset) }) } ?? [:]
        updatePlayback()
    }

    /// Compiles before publication. A bad library leaves the previous rendered player intact.
    func installAnimationLibraries(_ libraries: [AnimationLibrary]) throws {
        guard let rig = asset?.animationRig else {
            if libraries.isEmpty { return }
            throw AssetError.message("Model has no animation rig.")
        }
        var clips: [SkeletalAnimationClip] = []
        var names = Set(asset?.animationClips.map(\.name) ?? [])
        for library in libraries {
            for clip in try library.compiledClips(for: rig) {
                guard names.insert(clip.name).inserted else { throw AssetError.message("Animation reference collision.") }
                clips.append(clip)
            }
        }
        authoredClips = clips
        libraryGeneration &+= 1
        updatePlayback()
    }

    func capturedAnimationPlayer() -> SkeletalAnimationPlayer? {
        guard let world, let animationRoot else { return nil }
        return world.getEntityByID(animationRoot)?.components[ModelAnimation3DComponent.self]?.player
    }

    var playbackTime: Double { capturedAnimationPlayer()?.time ?? pendingSeekTime ?? 0 }

    func load(_ document: EditorAssetDocument) {
        load(path: document.absolutePath)
    }

    func load(path: String?, resourceRoot: URL? = nil) {
        loadTask?.cancel()
        asset = nil
        normalizationCache = nil
        world = nil
        authoredClips = []
        appliedLibraryGeneration = nil
        animationRoot = nil
        voxelRoot = nil
        pendingSeekTime = nil
        error = nil
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                guard let path else { throw AssetError.message("Model file is unavailable.") }
                let loaded: ModelAsset3D?
                if let resourceRoot { loaded = try await Self.loadAuthoringModel(path: path, resourceRoot: resourceRoot) }
                else { loaded = try await AssetsManager.load(ModelAsset3D.self, at: path).asset }
                let lightingPath = Bundle.editor.resourceURL?.appendingPathComponent("Assets/PreviewLighting/Studio.ibl").path
                let lighting = try await AssetsManager.load(ImageBasedLighting3D.self, at: lightingPath ?? "Assets/PreviewLighting/Studio.ibl")
                try Task.checkCancellation()
                guard let asset = loaded else { throw AssetError.message("Model has not loaded.") }
                self?.previewLighting = lighting
                self?.asset = asset
            } catch is CancellationError {
                return
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isLoading = false
        }
    }

    func cancel() { loadTask?.cancel() }

    @concurrent
    private static func loadAuthoringModel(path: String, resourceRoot: URL) async throws -> ModelAsset3D {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let model = try await ModelAsset3D(gltfAt: url,
                                          loader: NativeGLTFLoader(resourceRoot: resourceRoot, maximumTotalBytes: 32 * 1024 * 1024))
        try Task.checkCancellation()
        return model
    }

    func bind(to world: World) {
        self.world = world
        appliedLibraryGeneration = nil
        animationRoot = world.getEntities().first { $0.components[ModelAnimation3DComponent.self] != nil }?.id
        voxelRoot = world.getEntities().first { $0.components[VoxelAnimationPlayback3DComponent.self] != nil }?.id
        updatePlayback()
        if let time = pendingSeekTime { seekGraph(to: time) }
        applyMorphWeights()
    }

    private func applyMorphWeights() {
        guard let world, !morphWeights.isEmpty else { return }
        for entity in world.getEntities() {
            guard var component = entity.components[MorphWeights3DComponent.self] else { continue }
            var changed = false
            for (name, weight) in morphWeights where weight.isFinite {
                if component.weight(named: name) != weight, component.setWeight(weight, named: name) { changed = true }
            }
            if changed { entity.components[MorphWeights3DComponent.self] = component }
        }
    }

    /// Whether the previewed asset is a MagicaVoxel scene with animation to play.
    var hasVoxelAnimation: Bool { asset?.voxelTimeline != nil }

    /// Frame count and rate of the voxel timeline, for display.
    var voxelTimelineDescription: String? {
        asset?.voxelTimeline.map { "\($0.frameCount) frames at \(Int($0.framesPerSecond)) fps" }
    }

    private func updateVoxelPlayback() {
        guard let world, let voxelRoot, let root = world.getEntityByID(voxelRoot),
            var playback = root.components[VoxelAnimationPlayback3DComponent.self] else { return }
        playback.isPlaying = playsAnimation
        root.components[VoxelAnimationPlayback3DComponent.self] = playback
    }

    private func updatePlayback() {
        updateVoxelPlayback()
        guard let world, let animationRoot, let root = world.getEntityByID(animationRoot),
            var component = root.components[ModelAnimation3DComponent.self] else { return }
        do {
            let priorClock = component.player.time
            let replacedLibrary = appliedLibraryGeneration != libraryGeneration
            if appliedLibraryGeneration != libraryGeneration {
                let clock = component.player.time
                component.player = try SkeletalAnimationPlayer(rig: component.player.rig, clips: (asset?.animationClips ?? []) + authoredClips)
                component.player.seek(to: clock)
            }
            component.player.repeats = animationRepeats
            component.player.speed = playbackSpeed.isFinite ? playbackSpeed : 1
            if let animationGraph {
                if component.player.graph != animationGraph {
                    let clock = replacedLibrary ? priorClock : component.player.graph == nil ? 0 : component.player.time
                    try component.player.play(animationGraph, transitionDuration: 0)
                    component.player.seek(to: clock)
                }
                component.player.isPlaying = playsAnimation
            } else if animation.isEmpty {
                component.player = try SkeletalAnimationPlayer(rig: component.player.rig, clips: component.player.clips)
            } else {
                if component.player.clipIndex.map({ component.player.clips[$0].name }) != animation {
                    try component.player.play(animation, transitionDuration: 0, startTime: replacedLibrary ? priorClock : 0)
                }
                component.player.isPlaying = playsAnimation
            }
            let modifiers = modifierStack?.modifiers ?? []
            if component.player.poseModifiers != modifiers {
                let binding = modifierStack?.binding ?? AnimationRigBinding(rig: component.player.rig, sourceAsset: "")
                try component.player.setPoseModifiers(modifiers, binding: binding)
            }
            root.components[ModelAnimation3DComponent.self] = component
            modifierDiagnostics = component.player.modifierDiagnostics
            appliedLibraryGeneration = libraryGeneration
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func seekGraph(to time: Double) {
        guard time.isFinite else { return }
        guard let world, let animationRoot, let root = world.getEntityByID(animationRoot),
            var component = root.components[ModelAnimation3DComponent.self] else {
            pendingSeekTime = time
            return
        }
        pendingSeekTime = nil
        component.player.seek(to: time)
        root.components[ModelAnimation3DComponent.self] = component
        modifierDiagnostics = component.player.modifierDiagnostics
    }

    func pollGraphEvents(in world: World) {
        if let animationRoot, let player = world.getEntityByID(animationRoot)?.components[ModelAnimation3DComponent.self]?.player,
           modifierDiagnostics != player.modifierDiagnostics { modifierDiagnostics = player.modifierDiagnostics }
        guard animationGraph != nil, world.supportsEventDelivery else {
            return
        }
        let events = Events<ModelAnimation3DEvent>(from: world)
        events.update(from: world)
        let messages = events.wrappedValue.filter { $0.modelRoot == animationRoot }.map {
            "\($0.animation.clip): \($0.animation.marker.name) · \($0.animation.marker.payload)"
        }
        if !messages.isEmpty { graphEventLog = Array((graphEventLog + messages).suffix(8)) }
    }

    var animationNames: [String] { ["Rest pose"] + (asset?.animationClips.map(\.name) ?? []) }
    var animation: String { selectedAnimation == "Rest pose" ? "" : selectedAnimation }

    var normalizationTransform: Transform { normalization().1 }
    var normalizedBounds: AABB { normalization().2 }

    private func normalization() -> (ObjectIdentifier?, Transform, AABB) {
        guard let asset else { return (nil, Transform(), .empty) }
        let id = ObjectIdentifier(asset)
        if let cached = normalizationCache, cached.0 == id { return (id, cached.1, cached.2) }
        let bounds = Self.bounds(of: asset)
        let extent = max(bounds.halfExtents.x, max(bounds.halfExtents.y, bounds.halfExtents.z))
        let scale = extent > 0.0001 ? 1.5 / extent : 1
        let transform = Transform(scale: Vector3(scale), position: -bounds.center * scale)
        let normalized = AABB(center: .zero, halfExtents: bounds.halfExtents * scale)
        normalizationCache = (id, transform, normalized)
        return (id, transform, normalized)
    }

    static func bounds(of asset: ModelAsset3D) -> AABB {
        var minimum = Vector3(Float.greatestFiniteMagnitude)
        var maximum = Vector3(-Float.greatestFiniteMagnitude)
        var visited: Set<Int> = []
        func visit(_ index: Int, parent: Transform3D) {
            guard asset.nodes.indices.contains(index), visited.insert(index).inserted else {
                return
            }
            let node = asset.nodes[index]
            let transform = parent * node.transform
            if let meshIndex = node.meshIndex, asset.meshes.indices.contains(meshIndex) {
                let box = asset.meshes[meshIndex].bounds
                for x in [box.min.x, box.max.x] {
                    for y in [box.min.y, box.max.y] {
                        for z in [box.min.z, box.max.z] {
                            let point = (transform * Vector4(x, y, z, 1)).xyz
                            for axis in 0..<3 {
                                minimum[axis] = min(minimum[axis], point[axis])
                                maximum[axis] = max(maximum[axis], point[axis])
                            }
                        }
                    }
                }
            }
            for child in node.children { visit(child, parent: transform) }
        }
        let scene = asset.defaultScene ?? 0
        if asset.scenes.indices.contains(scene) {
            for root in asset.scenes[scene] { visit(root, parent: .identity) }
        }
        return minimum.x == Float.greatestFiniteMagnitude ? .empty : AABB(min: minimum, max: maximum)
    }
}

struct EditorModelAssetPreview: View {
    let document: EditorAssetDocument
    let workbench: EditorWorkbenchViewModel
    private var workspace: EditorAnimationAssetWorkspace { workbench.animationWorkspace(for: document) }
    private var model: EditorModelAssetPreviewModel { workspace.preview }
    private var camera: EditorModelPreviewCamera { workspace.camera }
    @State private var showsScenePicker = false
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                header
                if showsScenePicker {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Choose destination scene")).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                            ForEach(targetScenes, id: \.id) { scene in
                                Button(action: { place(in: scene.id) }) {
                                    Text(scene.relativePath).font(.system(size: 12)).foregroundColor(theme.editorColors.blue)
                                }
                                .buttonStyle(DefaultButtonStyle())
                                .accessibilityIdentifier("AdaEditor.ModelPreview.Scene.\(scene.id)")
                            }
                        }
                    }
                    .frame(height: 100)
                }
                ZStack {
                    RoundedRectangleShape(cornerRadius: 10).fill(Color.fromHex(0x24282F))
                    EditorAnimationAssetViewport(workspace: workspace)
                }
                .frame(height: max(0, geometry.size.height - (showsScenePicker ? 168 : 56)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.ModelPreview")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title).font(.system(size: 14, weight: .bold)).foregroundColor(theme.editorColors.text)
                if let asset = model.asset {
                    if asset.voxelTimeline != nil || document.title.lowercased().hasSuffix(".vox") {
                        Text(["\(asset.meshes.count) voxel meshes", model.voxelTimelineDescription].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                    } else {
                        Text(L10n.text("\(asset.meshes.count) meshes · \(asset.materials.count) materials · \(asset.skins.count) skins"))
                            .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                    }
                }
            }
            Spacer()
            Button(action: { camera.reset() }) {
                Text(L10n.text("Frame model")).font(.system(size: 12))
            }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors))
            .accessibilityIdentifier("AdaEditor.ModelPreview.Frame")
            addToScene
        }
        .frame(height: 44)
    }

    private var targetScenes: [EditorSceneDocument] {
        workbench.openDocuments.compactMap { document in
            guard case let .scene(scene) = document, !scene.isReadOnly, scene.sceneModel != nil else {
                return nil
            }
            return scene
        }
    }

    private var addToScene: some View {
        Button(action: {
            if targetScenes.count == 1, let scene = targetScenes.first {
                place(in: scene.id)
            } else {
                showsScenePicker.toggle()
            }
        }) {
            Text(targetScenes.count == 1 ? L10n.text("Add to Scene") : L10n.text("Add to Scene…"))
                .font(.system(size: 12))
        }
        .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, prominent: true))
        .disabled(model.asset == nil || targetScenes.isEmpty || document.assetReference == nil || workspace.library?.isDirty == true
            || workspace.mode == .graph && workspace.graph.validGraph == nil)
        .accessibilityIdentifier("AdaEditor.ModelPreview.AddToScene")
    }

    private func place(in sceneID: String) {
        if ["glb", "gltf"].contains(document.fileExtension.lowercased()) {
            let animation = model.animation
            let autoplay = model.playsAnimation
            let repeats = model.animationRepeats
            let graph = workspace.mode == .graph ? workspace.graph.validGraph : nil
            let library = workspace.library
            workspace.run {
                _ = try await workbench.addAnimatedModelAsset(document, to: sceneID, animation: animation,
                    autoplay: autoplay, repeats: repeats, graph: graph, library: library)
            }
        } else {
            workbench.addModelAsset(document, to: sceneID, animation: model.animation, autoplay: model.playsAnimation)
        }
        showsScenePicker = false
    }
}

extension EditorWorkbenchViewModel {
    @discardableResult
    func addModelAsset(_ asset: EditorAssetDocument, to documentID: String, animation: String = "", autoplay: Bool = false,
                       animationGraph: AnimationGraph? = nil, animationLibraries: [String] = [], repeats: Bool = true) -> Bool {
        guard let reference = asset.assetReference, asset.kind == .model3D,
            let document = sceneDocument(id: documentID), !document.isReadOnly, document.sceneModel != nil else {
                return false
            }
        let graphValue: EditorSceneValue?
        do { graphValue = try animationGraph.map(EditorAnimationGraphPayload.encode) } catch { return false }
        selectDocument(id: documentID)
        updateSceneModelDocument(id: documentID, status: "Model added") { scene in
            let entity = scene.addEntity(template: .importedModel3D, parentID: scene.editor?.selectedEntity)
            guard let index = scene.entities.firstIndex(where: { $0.id == entity.id }) else {
                return
            }
            scene.entities[index].name = URL(fileURLWithPath: asset.title).deletingPathExtension().lastPathComponent
            scene.entities[index].components[EditorBuiltInComponentType.model3DSource] = [
                "source": .string(reference), "animation": .string(animation), "autoplay": .bool(autoplay), "repeats": .bool(repeats),
            ]
            scene.entities[index].components[EditorBuiltInComponentType.model3DSource]?["animationGraph"] = graphValue
            if !animationLibraries.isEmpty {
                scene.entities[index].components[EditorBuiltInComponentType.model3DSource]?["animationLibraries"] = .array(animationLibraries.map(EditorSceneValue.string))
            }
        }
        return true
    }
}
