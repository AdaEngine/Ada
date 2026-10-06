@_spi(AdaEngine) import AdaEngine
import Foundation

/// Scene authoring uses an independent real model preview; applying is one undoable transaction.
struct EditorSkeletalAnimatorPanel: View {
    let viewModel: EditorViewModel
    let target: EditorSkeletalAnimationTarget
    @State private var graphModel = EditorAnimationGraphModel()
    @State private var preview = EditorModelAssetPreviewModel()
    @State private var camera = EditorModelPreviewCamera()
    @State private var seekTime = "0"
    @State private var autoplay = false
    @State private var status = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            if preview.isLoading {
                Text("Loading animation model…").font(.system(size: 12))
            } else if let error = preview.error {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
            } else if preview.asset != nil {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        EditorModelPreviewViewport(model: preview, camera: camera)
                            .frame(minHeight: 130)
                        Text(preview.graphEventLog.last ?? "Event markers appear here during playback")
                            .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                            .accessibilityIdentifier("AdaEditor.AnimationGraph.EventLog")
                    }
                    .frame(width: 220)
                    EditorAnimationGraphEditor(model: graphModel)
                }
                .frame(maxHeight: .infinity)
            }
            if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundColor(theme.editorColors.muted) }
        }
        .padding(8)
        .onAppear { load() }
        .onDisappear { preview.cancel() }
        .onChange(of: target.source) { old, new in
            if old.source != new.source { load() } else { configure() }
        }
        .onChange(of: preview.asset.map(ObjectIdentifier.init)) { _, _ in configure() }
        .onChange(of: graphModel.graph) { _, _ in
            if let graph = graphModel.validGraph {
                preview.animationGraph = graph
                preview.graphEventLog = []
            }
        }
        .accessibilityIdentifier("AdaEditor.Animator.SkeletalGraph")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("SKELETAL GRAPH").font(.system(size: 11, weight: .semibold))
            action(preview.playsAnimation ? "Pause" : "Play", id: "Play") { preview.playsAnimation.toggle() }
            TextField("Seconds", text: $seekTime).font(.system(size: 11)).frame(width: 55, height: 26)
                .accessibilityIdentifier("AdaEditor.AnimationGraph.SeekTime")
            action("Seek", id: "Seek") {
                if let value = Double(seekTime), value.isFinite { preview.seekGraph(to: value) }
            }
            action(autoplay ? "Autoplay: On" : "Autoplay: Off", id: "Autoplay") { autoplay.toggle() }
            Spacer()
            action("Apply to Scene", id: "Apply") {
                do {
                    guard let graph = graphModel.validGraph else {
                        return
                    }
                    if try viewModel.workbench.setAnimationGraph(graph, target: target, autoplay: autoplay) {
                        status = "Applied to scene. Save the scene to keep this graph."
                    }
                } catch { status = error.localizedDescription }
            }
            .disabled(graphModel.validGraph == nil || viewModel.workbench.activeSceneDocument?.isReadOnly == true)
            action("Use Single Clip", id: "Clear") {
                do { _ = try viewModel.workbench.setAnimationGraph(nil, target: target) } catch { status = error.localizedDescription }
            }
            .disabled(target.source.animationGraph == nil || viewModel.workbench.activeSceneDocument?.isReadOnly == true)
        }
    }

    private func action(_ title: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11)).padding(4) }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.AnimationGraph.\(id)")
    }

    private func load() {
        do {
            let url = try EditorModelResource.resolve(target.source.source, sourceURL: target.sceneURL, resourceRootURL: viewModel.projectAssetsURL)
            preview.load(path: url.path)
        } catch {
            preview.isLoading = false
            preview.error = error.localizedDescription
        }
    }

    private func configure() {
        guard let asset = preview.asset else {
            return
        }
        graphModel.configure(asset: asset, graph: target.source.animationGraph)
        autoplay = target.source.autoplay
        if let graph = graphModel.validGraph { preview.animationGraph = graph }
    }
}
