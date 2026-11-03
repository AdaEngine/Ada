@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorSceneLoadingProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case document, collecting, resources, objects }
    var phase: Phase = .collecting
    var completed = 0
    var total = 0
    var resourceName: String?

    var fractionCompleted: Float? {
        phase == .resources && total > 0 ? Float(completed) / Float(total) : nil
    }
}

struct EditorSceneLoadingProgressView: View {
    let progress: EditorSceneLoadingProgress
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(theme.editorColors.text)
                .accessibilityIdentifier("AdaEditor.SceneViewport.Loading.Phase")
            EditorLoadingProgressBar(fractionCompleted: progress.fractionCompleted)
            if let name = progress.resourceName, progress.phase == .resources {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
                    .frame(width: 300)
            }
        }
        .padding(20)
        .background(theme.editorColors.surface)
        .accessibilityIdentifier("AdaEditor.SceneViewport.Loading")
    }

    private var title: String {
        switch progress.phase {
        case .document: L10n.text("Reading scene data…")
        case .collecting: L10n.text("Finding scene resources…")
        case .resources: progress.total > 0
            ? L10n.text("Loading resources: \(progress.completed) of \(progress.total)") : L10n.text("Finding scene resources…")
        case .objects: L10n.text("Creating scene objects…")
        }
    }
}
