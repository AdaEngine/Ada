@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Observation

@Observable
@MainActor
final class EditorModelAssetPreviewModel {
    var asset: ModelAsset3D?
    var error: String?
    var isLoading = true
    var selectedAnimation = "Rest pose" { didSet { updatePlayback() } }
    var playsAnimation = true { didSet { updatePlayback() } }
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var normalizationCache: (ObjectIdentifier, Transform, AABB)?
    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private var animationRoot: Entity.ID?

    func load(_ document: EditorAssetDocument) {
        loadTask?.cancel()
        asset = nil
        normalizationCache = nil
        world = nil
        animationRoot = nil
        error = nil
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                guard let path = document.absolutePath else { throw AssetError.message("Model file is unavailable.") }
                let handle = try await AssetsManager.load(ModelAsset3D.self, at: path)
                try Task.checkCancellation()
                guard let asset = handle.asset else { throw AssetError.message("Model has not loaded.") }
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

    func bind(to world: World) {
        self.world = world
        animationRoot = world.getEntities().first { $0.components[ModelAnimation3DComponent.self] != nil }?.id
        updatePlayback()
    }

    private func updatePlayback() {
        guard let world, let animationRoot, let root = world.getEntityByID(animationRoot),
            var component = root.components[ModelAnimation3DComponent.self] else { return }
        do {
            if animation.isEmpty {
                component.player = try SkeletalAnimationPlayer(rig: component.player.rig, clips: component.player.clips)
            } else {
                if component.player.clipIndex.map({ component.player.clips[$0].name }) != animation {
                    try component.player.play(animation, transitionDuration: 0)
                }
                component.player.isPlaying = playsAnimation
            }
            root.components[ModelAnimation3DComponent.self] = component
        } catch {
            self.error = error.localizedDescription
        }
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
    let resourceRootURL: URL?
    @State private var model = EditorModelAssetPreviewModel()
    @State private var camera = EditorModelPreviewCamera()
    @State private var showsScenePicker = false
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                header
                if showsScenePicker {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Choose destination scene").font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
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
                    if model.isLoading {
                        Text("Loading model…").foregroundColor(theme.editorColors.muted)
                    } else if let error = model.error {
                        Text(error).foregroundColor(.red).padding(24)
                    } else if model.asset != nil {
                        EditorModelPreviewViewport(model: model, camera: camera)
                    }
                }
                .frame(height: max(180, geometry.size.height - (showsScenePicker ? 210 : 110)))
                animationControls
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.ModelPreview")
        .onAppear { model.load(document) }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title).font(.system(size: 14, weight: .bold)).foregroundColor(theme.editorColors.text)
                if let asset = model.asset {
                    Text("\(asset.meshes.count) meshes · \(asset.materials.count) materials · \(asset.skins.count) skins")
                        .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                }
            }
            Spacer()
            Button(action: { camera.reset() }) {
                Text("Frame model").font(.system(size: 12)).foregroundColor(theme.editorColors.text).padding(8)
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.ModelPreview.Frame")
            addToScene
        }
        .frame(height: 44)
    }

    private var animationControls: some View {
        HStack(spacing: 8) {
            Text("Animation").font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            EditorEnumField(
                cases: model.animationNames,
                selection: Binding(get: { model.selectedAnimation }, set: { model.selectedAnimation = $0 }),
                accessibilityID: "AdaEditor.ModelPreview.Animation"
            )
                .frame(maxWidth: 260)
            Button(action: { model.playsAnimation.toggle() }) {
                Text(model.playsAnimation ? "Pause" : "Play").font(.system(size: 11))
            }
            .buttonStyle(DefaultButtonStyle())
            .disabled(model.animation.isEmpty)
            .accessibilityIdentifier("AdaEditor.ModelPreview.PlayAnimation")
            Spacer()
        }
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
            Text(targetScenes.count == 1 ? "Add to Scene" : "Add to Scene…")
                .font(.system(size: 12)).foregroundColor(theme.editorColors.blue)
                .padding(8)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.blue.opacity(0.12)))
        }
        .buttonStyle(DefaultButtonStyle())
        .disabled(model.asset == nil || targetScenes.isEmpty || document.assetReference == nil)
        .accessibilityIdentifier("AdaEditor.ModelPreview.AddToScene")
    }

    private func place(in sceneID: String) {
        workbench.addModelAsset(document, to: sceneID, animation: model.animation, autoplay: model.playsAnimation)
        showsScenePicker = false
    }
}

extension EditorWorkbenchViewModel {
    @discardableResult
    func addModelAsset(_ asset: EditorAssetDocument, to documentID: String, animation: String = "", autoplay: Bool = false) -> Bool {
        guard let reference = asset.assetReference, asset.kind == .model3D,
            let document = sceneDocument(id: documentID), !document.isReadOnly, document.sceneModel != nil else {
                return false
            }
        selectDocument(id: documentID)
        updateSceneModelDocument(id: documentID, status: "Model added") { scene in
            let entity = scene.addEntity(template: .importedModel3D, parentID: scene.editor?.selectedEntity)
            guard let index = scene.entities.firstIndex(where: { $0.id == entity.id }) else {
                return
            }
            scene.entities[index].name = URL(fileURLWithPath: asset.title).deletingPathExtension().lastPathComponent
            scene.entities[index].components[EditorBuiltInComponentType.model3DSource] = [
                "source": .string(reference), "animation": .string(animation), "autoplay": .bool(autoplay), "repeats": .bool(true),
            ]
        }
        return true
    }
}
