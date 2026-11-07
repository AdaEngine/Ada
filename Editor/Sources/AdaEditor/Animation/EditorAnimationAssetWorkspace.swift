@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

/// UI state owned by an open asset, independently of the Animator's visibility and selected mode.
/// Resource contents, revisions and Undo remain in the project authoring service.
@Observable
@MainActor
final class EditorAnimationAssetWorkspace {
    enum Mode: String, CaseIterable { case clips, keys, curves, graph }
    let document: EditorAssetDocument
    let preview = EditorModelAssetPreviewModel()
    let camera = EditorModelPreviewCamera()
    let graph = EditorAnimationGraphModel()
    let timeline = EditorAnimationTimelineModel()
    var sourceLibrary: AnimationLibrary?
    var mode = Mode.keys
    var library: EditorAnimationLibraryDocument?
    var modifiers: EditorAnimationModifierDocument?
    var modifierPath = ""
    var selectedModifierID: String? { didSet { preview.selectedPoseModifierID = selectedModifierID } }
    var libraryPath = ""
    var clipName = ""
    var sourceClip = ""
    var seekTime = "0"
    var error = ""
    private(set) var isWorking = false
    private(set) var isChangingLibrary = false
    @ObservationIgnored let service: EditorAnimationAuthoringService?
    @ObservationIgnored weak var workbench: EditorWorkbenchViewModel?
    @ObservationIgnored var revealInspector: (() -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored var modifierDrag: EditorAnimationModifierDrag?

    init(document: EditorAssetDocument, service: EditorAnimationAuthoringService?) {
        self.document = document
        self.service = service
        timeline.workspace = self
        preview.onModifierInput = { [weak self] event, camera in self?.handleModifierInput(event, camera: camera) ?? false }
        preview.onSelectBone = { [weak self] index, additive in
            guard let self, timeline.nodes.indices.contains(index) else { return }
            timeline.selectNode(timeline.nodes[index].id, additive: additive)
        }
        graph.onInspect = { [weak self] in self?.timeline.inspectorMode = "graph" }
        preview.playsAnimation = false
        if let service {
            let assets = String(service.assetsURL.path.dropFirst(service.projectURL.path.count + 1))
            libraryPath = assets + "/Animations/" + URL(fileURLWithPath: document.title).deletingPathExtension().lastPathComponent + ".animlib"
            modifierPath = assets + "/Animations/" + URL(fileURLWithPath: document.title).deletingPathExtension().lastPathComponent + ".animmod"
        }
        restoreWorkspaceState()
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            if document.kind == .animationModifiers {
                guard let service else { throw unavailable() }
                modifierPath = document.relativePath
                try openModifiers()
                let url = try service.resolve(modifiers?.stack.binding.sourceAsset ?? "", extensions: ["glb", "gltf"])
                preview.load(path: url.path, resourceRoot: service.assetsURL)
            } else if document.kind == .animationLibrary {
                guard let service else { throw unavailable() }
                libraryPath = document.relativePath
                library = try service.open(libraryPath)
                let url = try service.resolve(library?.library.binding.sourceAsset ?? "", extensions: ["glb", "gltf"])
                preview.load(path: url.path, resourceRoot: service.assetsURL)
            } else if ["glb", "gltf"].contains(document.fileExtension.lowercased()), let service {
                let url = try service.resolve(document.relativePath, extensions: ["glb", "gltf"])
                preview.load(path: url.path, resourceRoot: service.assetsURL)
            } else {
                mode = .clips
                preview.load(document)
            }
        } catch {
            preview.isLoading = false
            self.error = error.localizedDescription
            preview.error = error.localizedDescription
        }
    }

    func cancel() {
        cancelModifierDrag()
        do { try saveWorkspaceState() } catch { self.error = L10n.text("Unable to save animation workspace: \(error.localizedDescription)") }
        workTask?.cancel()
        preview.cancel()
        camera.endNavigation()
    }

    func configureLoadedAsset() {
        guard let asset = preview.asset else { return }
        if let rig = asset.animationRig {
            let source = modifiers?.stack.binding.sourceAsset
                ?? (document.kind == .animationLibrary ? library?.library.binding.sourceAsset ?? document.relativePath : document.relativePath)
            var imported = AnimationLibrary(id: "imported-preview", binding: .init(rig: rig, sourceAsset: source))
            do {
                for (index, clip) in asset.animationClips.enumerated() {
                    try imported.extract(clip, rig: rig, id: "source-\(index)")
                }
                sourceLibrary = imported
            } catch { self.error = error.localizedDescription }
        }
        if !asset.animationClips.contains(where: { $0.name == sourceClip }) { sourceClip = asset.animationClips.first?.name ?? "" }
        preview.selectedAnimation = sourceClip.isEmpty ? "Rest pose" : sourceClip
        graph.configure(asset: asset, graph: graph.graph.nodes.isEmpty ? nil : graph.graph)
        timeline.synchronizeBoneSelection()
        applyRequestedPreview()
        refreshModifiers()
    }

    func openLibrary() throws {
        guard !isChangingLibrary else { throw unavailable() }
        try requireNoUnkeyedPose()
        guard let service else { throw unavailable() }
        let candidate = try service.open(libraryPath)
        if let rig = preview.asset?.animationRig { _ = try candidate.library.compiledClips(for: rig) }
        library = candidate
        mode = .keys
        refreshLibrary()
    }

    func extract(fromRest: Bool) async throws {
        guard !isChangingLibrary else { throw unavailable() }
        try requireNoUnkeyedPose()
        isChangingLibrary = true
        defer { isChangingLibrary = false }
        guard let service else { throw unavailable() }
        let modelPath = sourceLibrary?.binding.sourceAsset ?? (document.kind == .animationLibrary ? library?.library.binding.sourceAsset : document.relativePath)
        guard let modelPath else { throw unavailable() }
        let result = try await service.extract(path: libraryPath, modelPath: modelPath,
            clipName: fromRest ? nil : sourceClip, name: clipName.isEmpty ? nil : clipName, expectedRevision: library?.revision)
        try Task.checkCancellation()
        library = result
        libraryPath = result.relativePath
        result.selectedClipID = result.library.clips.last?.id
        mode = .keys
        refreshLibrary()
    }

    /// Recompile the shared draft without replacing the viewport, camera or playback clock.
    func refreshLibrary() {
        guard !timeline.hasUnkeyedPose else { return }
        if library?.isDiscarded == true { library = nil; mode = .clips }
        guard let asset = preview.asset else { return }
        let clock = preview.playbackTime
        do {
            let libraries = library.map { [$0.library] } ?? []
            try preview.installAnimationLibraries(libraries)
            let clips = try libraries.flatMap { value in
                guard let rig = asset.animationRig else { throw unavailable() }
                return try value.compiledClips(for: rig)
            }
            var labels: [String: String] = [:]
            if let library {
                for clip in library.library.clips { labels[library.library.runtimeName(for: clip.id)] = clip.name }
            }
            let prior = graph.graph.nodes.isEmpty ? nil : graph.graph
            let selected = graph.selectedNodeID
            graph.configure(asset: asset, graph: prior, authoredClips: clips, clipLabels: labels)
            if graph.graph.nodes.contains(where: { $0.id == selected }) { graph.selectedNodeID = selected }
            applyModePreview()
            preview.seekGraph(to: clock)
            error = ""
        } catch { self.error = error.localizedDescription }
    }

    func applyModePreview() {
        guard !timeline.hasUnkeyedPose else { return }
        let clock = preview.playbackTime
        if mode == .graph {
            if let graph = graph.validGraph { preview.animationGraph = graph }
        } else {
            preview.animationGraph = nil
            if (mode == .keys || mode == .curves), let library,
                let clip = library.library.clips.first(where: { $0.id == library.selectedClipID }) ?? library.library.clips.first {
                preview.animationRepeats = clip.repeats
                preview.selectedAnimation = library.library.runtimeName(for: clip.id)
            } else {
                preview.animationRepeats = true
                preview.selectedAnimation = sourceClip.isEmpty ? "Rest pose" : sourceClip
            }
        }
        preview.seekGraph(to: clock)
    }

    func applyRequestedPreview() {
        guard !timeline.hasUnkeyedPose else { return }
        refreshLibrary()
        if let library, library.previewSerial > 0 {
            preview.playsAnimation = false
            preview.seekGraph(to: library.previewTime)
        }
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        workTask = Task { @MainActor in
            defer { isWorking = false }
            do { try await operation(); error = "" }
            catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }

    private func unavailable() -> AnimationAuthoringError {
        .init(.missingTarget, itemID: document.id, message: L10n.tr("Open a project to edit animations"))
    }

    func requireNoUnkeyedPose() throws {
        guard !timeline.hasUnkeyedPose else {
            throw AnimationAuthoringError(.conflict, itemID: document.id, message: L10n.tr("Insert or discard the unkeyed pose first."))
        }
    }
}

extension EditorWorkbenchViewModel {
    var animationAssetDocument: EditorAssetDocument? {
        guard case let .asset(document)? = activeDocument,
            document.kind == .model3D || document.kind == .animationLibrary || document.kind == .animationModifiers else { return nil }
        return document
    }

    func animationWorkspace(for document: EditorAssetDocument) -> EditorAnimationAssetWorkspace {
        if let existing = animationWorkspaces[document.id] { return existing }
        let workspace = EditorAnimationAssetWorkspace(document: document, service: animationService)
        workspace.workbench = self
        workspace.revealInspector = { [weak self] in self?.onRevealAnimationInspector?() }
        animationWorkspaces[document.id] = workspace
        return workspace
    }
}

extension EditorViewModel {
    func revealAssetAnimatorIfNeeded() {
        guard let asset = workbench.animationAssetDocument,
            asset.kind == .animationLibrary || asset.kind == .animationModifiers || ["glb", "gltf"].contains(asset.fileExtension.lowercased()) else { return }
        toolStrip.selectLeftBottomTool(.init(identifier: "animator", title: "Animator", icon: "\u{E71C}"))
        showBottomPanel = true
    }
}
