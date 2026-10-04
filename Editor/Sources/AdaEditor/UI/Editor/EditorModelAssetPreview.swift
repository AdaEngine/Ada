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
    @ObservationIgnored private var previewScene: EditorSceneModel?
    @ObservationIgnored private var previewCache: EditorSceneDocument?
    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private var animationRoot: Entity.ID?

    func load(_ document: EditorAssetDocument) {
        loadTask?.cancel()
        asset = nil
        previewScene = nil
        previewCache = nil
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

    func previewDocument(for document: EditorAssetDocument) throws -> EditorSceneDocument {
        guard let asset else { throw AssetError.message("Model has not loaded.") }
        if let previewCache {
            return previewCache
        }
        if previewScene == nil {
            var scene = EditorSceneModel.default(projectName: document.title)
            _ = scene.addEntity(template: .importedModel3D, parentID: scene.rootEntityID)
            _ = scene.addEntity(template: .directionalLight3D, parentID: scene.rootEntityID)
            previewScene = scene
        }
        guard var scene = previewScene else { throw AssetError.message("Unable to prepare model preview.") }
        let bounds = Self.bounds(of: asset)
        let extent = max(bounds.halfExtents.x, max(bounds.halfExtents.y, bounds.halfExtents.z))
        let scale = extent > 0.0001 ? 1.5 / extent : 1
        if let index = scene.entities.firstIndex(where: { $0.components[EditorBuiltInComponentType.model3DSource] != nil }) {
            scene.entities[index].components[EditorBuiltInComponentType.model3DSource] = [
                "source": .string(document.assetReference ?? document.absolutePath ?? ""),
                "animation": .string(""), "autoplay": .bool(false), "repeats": .bool(true),
            ]
            scene.entities[index].components[EditorBuiltInComponentType.transform]?["scale"] = .array([.double(Double(scale)), .double(Double(scale)), .double(Double(scale))])
            let position = -bounds.center * scale
            scene.entities[index].components[EditorBuiltInComponentType.transform]?["position"] = .array(
                [.double(Double(position.x)), .double(Double(position.y)), .double(Double(position.z))]
            )
        }
        let content = try scene.encodedYAML()
        let preview = EditorSceneDocument(
            id: "model-preview:\(document.id)",
            title: document.title,
            relativePath: document.relativePath,
            absolutePath: document.absolutePath,
            content: content,
            isReadOnly: true,
            sceneModel: scene,
            isDirty: false,
            loadSummary: .init(entityCount: scene.entities.count, warnings: [])
        )
        previewCache = preview
        return preview
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
    @State private var inspector = EditorInspectorSidebarViewModel()
    @State private var showsScenePicker = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(document.title).font(.system(size: 14)).foregroundColor(theme.editorColors.text)
                Spacer()
                addToScene
            }
            if showsScenePicker {
                VStack(alignment: .leading, spacing: 4) {
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
            if model.isLoading {
                Text("Loading model…").foregroundColor(theme.editorColors.muted)
            } else if let error = model.error {
                Text(error).foregroundColor(.red)
            } else if let preview = try? model.previewDocument(for: document) {
                animationControls
                Text("\(model.asset?.meshes.count ?? 0) meshes · \(model.asset?.materials.count ?? 0) materials · \(model.asset?.skins.count ?? 0) skins")
                    .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                EditorSceneViewportView(
                    document: preview,
                    resourceRootURL: document.assetReference == nil ? document.absolutePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } : resourceRootURL,
                    inspectorViewModel: inspector,
                    playModeState: .editing,
                    playRuntime: nil,
                    onEntitySelected: nil,
                    onPlay: nil,
                    onStop: nil,
                    onDocumentChanged: { _ in },
                    initialDisplayMode: .threeD,
                    isAssetPreview: true,
                    onEditWorldReady: { model.bind(to: $0) }
                )
                .frame(minHeight: 180, maxHeight: .infinity)
            }
            Text(placementHint)
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.ModelPreview")
        .onAppear { model.load(document) }
        .onDisappear { model.cancel() }
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

    private var placementHint: String {
        if targetScenes.isEmpty {
            return "Open a scene to add this model."
        }
        if document.assetReference == nil {
            return "Import this model into Assets to add it to a scene."
        }
        return "Add to Scene keeps the model's original scale."
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
