@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorSkeletalKeyframePanel: View {
    let viewModel: EditorViewModel
    let target: EditorSkeletalAnimationTarget
    @State private var sourceClips: [String] = []
    @State private var sourceLoadTask: Task<Void, Never>?
    @State private var library: EditorAnimationLibraryDocument?
    @State private var path = ""
    @State private var name = ""
    @State private var sourceClip = ""
    @State private var error = ""
    @State private var isWorking = false
    @State private var workTask: Task<Void, Never>?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                TextField(L10n.text("Animation library path"), text: $path).frame(minWidth: 130).frame(height: 28)
                TextField(L10n.text("Clip name"), text: $name).frame(width: 110, height: 28)
                Button { cycleSource() } label: { Text(sourceClip.isEmpty ? L10n.tr("Imported clip") : sourceClip).font(.system(size: 11)) }
                command("Extract Editable Copy") { try await importClip(fromRest: false) }.disabled(isWorking || sourceClip.isEmpty)
                command("New Animation") { try await importClip(fromRest: true) }.disabled(isWorking)
                command("Open Library") {
                    guard let service = viewModel.workbench.animationService else { throw unavailable() }
                    library = try service.open(path)
                }.disabled(isWorking)
                if let library {
                    command("Save and Bind") {
                        guard let scene = viewModel.workbench.sceneDocument(id: target.documentID),
                            let clip = library.library.clips.first(where: { $0.id == library.selectedClipID }) ?? library.library.clips.first else { throw unavailable() }
                        let revision = EditorAgentSceneToolService.revision(for: scene.content)
                        try library.save(expectedRevision: library.revision)
                        try await viewModel.workbench.bindAnimationLibrary(library, sceneID: target.documentID, entityID: target.entityID,
                            expectedSceneRevision: revision, expectedResourceRevision: library.revision, clipID: clip.id)
                        viewModel.refreshProjectFiles(logsRefresh: false)
                    }.disabled(isWorking)
                }
            }
            if let library, let service = viewModel.workbench.animationService {
                EditorAnimationLibraryEditor(document: library, service: service).id(library.url.path)
            } else {
                Text(L10n.text("Choose an imported clip to copy, or create an animation from the rig's rest pose."))
                    .font(.system(size: 12)).padding(8)
            }
            if !error.isEmpty { Text(error).foregroundColor(.red).font(.system(size: 11)) }
        }.padding(6)
        .textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors, height: 28))
        .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors))
        .foregroundColor(theme.editorColors.text)
        .onAppear { load() }
        .onDisappear { workTask?.cancel(); sourceLoadTask?.cancel() }
        .accessibilityIdentifier("AdaEditor.Animator.BoneKeyframes")
    }

    private func command(_ title: String, perform: @escaping () async throws -> Void) -> some View {
        Button {
            isWorking = true
            workTask = Task { @MainActor in
                defer { isWorking = false }
                do { try await perform(); error = "" }
                catch { self.error = L10n.text("Animation edit failed: \(error.localizedDescription)") }
            }
        } label: { Text(L10n.tr(title)).font(.system(size: 11)).padding(3) }
    }

    private func load() {
        do {
            guard let service = viewModel.workbench.animationService else { throw unavailable() }
            let url = try EditorModelResource.resolve(target.source.source, sourceURL: target.sceneURL, resourceRootURL: service.assetsURL)
            sourceLoadTask?.cancel()
            sourceClips = []
            sourceClip = ""
            sourceLoadTask = Task { @MainActor in
                do {
                    let imported = try await service.animationsForModel(String(url.path.dropFirst(service.projectURL.path.count + 1)))
                    try Task.checkCancellation()
                    sourceClips = imported.clips.map(\.name)
                    cycleSource()
                } catch is CancellationError { return }
                catch { self.error = L10n.text("Animation edit failed: \(error.localizedDescription)") }
            }
            let assets = String(service.assetsURL.path.dropFirst(service.projectURL.path.count + 1))
            path = assets + "/Animations/" + url.deletingPathExtension().lastPathComponent + ".animlib"
            if let first = target.source.animationLibraries.first,
                let url = EditorSceneFileLoader.resolveTileMapReference(first, relativeTo: target.sceneURL,
                    resourceRootURL: service.assetsURL, fileExtension: "animlib") {
                path = String(url.path.dropFirst(service.projectURL.path.count + 1))
                library = try service.open(path)
            }
        } catch { self.error = L10n.text("Animation edit failed: \(error.localizedDescription)") }
    }

    private func cycleSource() {
        let clips = sourceClips
        guard !clips.isEmpty else { sourceClip = ""; return }
        sourceClip = clips[((clips.firstIndex(of: sourceClip) ?? -1) + 1) % clips.count]
    }

    private func importClip(fromRest: Bool) async throws {
        guard let service = viewModel.workbench.animationService else { throw unavailable() }
        let url = try EditorModelResource.resolve(target.source.source, sourceURL: target.sceneURL, resourceRootURL: service.assetsURL)
        library = try await service.extract(path: path, modelPath: String(url.path.dropFirst(service.projectURL.path.count + 1)),
            clipName: fromRest ? nil : sourceClip, name: name.isEmpty ? nil : name, expectedRevision: library?.revision)
        library?.selectedClipID = library?.library.clips.last?.id
    }

    private func unavailable() -> AnimationAuthoringError {
        .init(.missingTarget, itemID: target.entityID, message: "Open an editable project scene with a compatible model.")
    }
}
