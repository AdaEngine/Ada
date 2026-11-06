@_spi(AdaEngine) import AdaEngine
import Foundation

/// Controls live in the bottom Animator; the center renders this workspace's only preview viewport.
struct EditorAnimationAssetPanel: View {
    let workspace: EditorAnimationAssetWorkspace
    let service: EditorAnimationAuthoringService?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            toolbar
            if workspace.mode == .graph {
                EditorAnimationGraphEditor(model: workspace.graph)
            } else if workspace.sourceLibrary != nil || workspace.library != nil {
                EditorAnimationTimeline(workspace: workspace)
            } else {
                Text(L10n.text("Choose an imported clip to copy, or create an animation from the rig's rest pose."))
                    .font(.system(size: 12)).padding(8)
                Spacer()
            }
            if !workspace.error.isEmpty {
                Text(L10n.text("Animation edit failed: \(workspace.error)")).font(.system(size: 11)).foregroundColor(.red)
            }
        }
        .padding(6)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .foregroundColor(theme.editorColors.text)
        .textFieldStyle(PlainTextFieldStyle())
        .onAppear { workspace.start() }
        .onChange(of: workspace.mode) { _, _ in workspace.applyModePreview() }
        .onChange(of: workspace.graph.graph) { _, _ in
            if workspace.mode == .graph { workspace.applyModePreview() }
        }
        .accessibilityIdentifier("AdaEditor.Animator.Asset")
    }

    private var clipBrowser: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(workspace.preview.asset?.animationClips ?? [], id: \.name) { clip in
                    action(clip.name, id: "Imported.\(clip.name)", localized: false, selected: workspace.preview.selectedAnimation == clip.name) {
                        workspace.sourceClip = clip.name
                        workspace.preview.animationGraph = nil
                        workspace.preview.animationRepeats = true
                        workspace.preview.selectedAnimation = clip.name
                    }
                }
                if let document = workspace.library {
                    Text(document.relativePath).font(.system(size: 11))
                    ForEach(document.library.clips, id: \.id) { clip in
                        action(clip.name, id: "Clip.\(clip.id)", localized: false,
                            selected: workspace.preview.selectedAnimation == document.library.runtimeName(for: clip.id)) {
                            document.selectedClipID = clip.id
                            workspace.mode = .keys
                            workspace.applyModePreview()
                        }
                    }
                }
                if let timeline = workspace.preview.voxelTimelineDescription { Text(timeline).font(.system(size: 11)) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(L10n.text("ANIMATOR")).font(.system(size: 11, weight: .semibold))
            mode(.clips, title: "Clips")
            mode(.keys, title: "Timeline")
            mode(.curves, title: "Curves")
            mode(.graph, title: "Animation Graph")
            action(workspace.preview.showsBones ? "Hide bones" : "Show bones", id: "Bones", selected: workspace.preview.showsBones) { workspace.preview.showsBones.toggle() }
            Spacer()
        }
    }

    private var sourceControls: some View {
        HStack(spacing: 6) {
            EditorEnumField(cases: workspace.preview.animationNames,
                selection: Binding(get: { workspace.sourceClip.isEmpty ? "Rest pose" : workspace.sourceClip }, set: {
                    workspace.sourceClip = $0 == "Rest pose" ? "" : $0
                    if workspace.mode == .clips || workspace.library == nil { workspace.preview.selectedAnimation = $0 }
                }), accessibilityID: "AdaEditor.Animator.Asset.ImportedClip", labels: ["Rest pose": L10n.tr("Rest pose")], localizesValues: false).frame(width: 160)
            field("Animation library path", text: Binding(get: { workspace.libraryPath }, set: { workspace.libraryPath = $0 }))
                .frame(minWidth: 140, maxWidth: 320).frame(height: 28)
            field("Clip name", text: Binding(get: { workspace.clipName }, set: { workspace.clipName = $0 })).frame(width: 110, height: 28)
            action("Extract Editable Copy", id: "Extract") { workspace.run { try await workspace.extract(fromRest: false) } }
                .disabled(workspace.isWorking || workspace.sourceClip.isEmpty || service == nil)
            action("New Animation", id: "New") { workspace.run { try await workspace.extract(fromRest: true) } }
                .disabled(workspace.isWorking || service == nil)
            action("Open Library", id: "Open") { workspace.run { try workspace.openLibrary() } }.disabled(workspace.isWorking || service == nil)
            Spacer()
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(L10n.tr(title), text: text).textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
    }

    private func mode(_ mode: EditorAnimationAssetWorkspace.Mode, title: String) -> some View {
        action(title, id: "Mode.\(mode.rawValue)", selected: workspace.mode == mode) { workspace.timeline.requestMode(mode) }
    }

    private func action(_ title: String, id: String, localized: Bool = true, selected: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(localized ? L10n.tr(title) : title).font(.system(size: 11)) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: selected))
            .accessibilityIdentifier("AdaEditor.Animator.Asset.\(id)")
    }
}

/// Only the center workbench instantiates a viewport. Control views never load or cancel this player.
struct EditorAnimationAssetViewport: View {
    let workspace: EditorAnimationAssetWorkspace
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if workspace.preview.isLoading { Text(L10n.text("Loading animation model…")).foregroundColor(theme.editorColors.muted) }
            else if let error = workspace.preview.error { Text(error).foregroundColor(.red).padding(16) }
            else if workspace.preview.asset != nil { EditorAnimationModelWorkspace(workspace: workspace) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { workspace.start() }
        .onChange(of: workspace.preview.asset.map(ObjectIdentifier.init)) { _, _ in workspace.configureLoadedAsset() }
        .onChange(of: workspace.library?.revision) { _, _ in workspace.refreshLibrary() }
        .onChange(of: workspace.library?.selectedClipID) { _, _ in workspace.refreshLibrary() }
        .onChange(of: workspace.library?.previewSerial) { _, _ in workspace.applyRequestedPreview() }
        .accessibilityIdentifier("AdaEditor.AnimationAsset.Viewport")
    }
}
