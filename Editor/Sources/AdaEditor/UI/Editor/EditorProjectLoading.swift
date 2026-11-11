@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

enum EditorProjectLoadingPhase: Int, CaseIterable, Sendable {
    case settings, files, scripts, document, workspace

    var titleKey: String {
        switch self {
        case .settings: "Reading project settings…"
        case .files: "Scanning project files…"
        case .scripts: "Preparing script components…"
        case .document: "Restoring the last open file…"
        case .workspace: "Preparing the workspace…"
        }
    }

    var fractionCompleted: Float { Float(rawValue) / Float(Self.allCases.count) }
}

struct EditorProjectStartupData: Sendable {
    let metadata: AdaProject
    let items: [EditorProjectSidebarViewModel.Item]
    let scriptSupport: EditorScriptableObjectCatalogLoader.Result?
    let restoredItem: EditorProjectSidebarViewModel.Item?
    let restoredDocument: EditorWorkbenchDocument?
    let savedDocumentPath: String?
}

enum EditorProjectStartupLoader {
    /// Foundation's directory traversal, script parsing and document reads are blocking.
    /// Run them on the concurrent executor; only immutable snapshots cross to the UI.
    @concurrent
    static func prepare(
        project: EditorProjectReference,
        onPhase: @Sendable (EditorProjectLoadingPhase) async -> Void = { _ in }
    ) async throws -> EditorProjectStartupData {
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        let fileManager = FileManager()
        try Task.checkCancellation()
        await onPhase(.settings)
        let metadata = try ProjectSystem.loadProject(at: root, fileManager: fileManager)
        try Task.checkCancellation()
        await onPhase(.files)
        let items = EditorViewModel.buildProjectTreeItems(at: root, fileManager: fileManager, projectMetadata: metadata)
        try Task.checkCancellation()
        await onPhase(.scripts)
        let support = metadata.build.system.isAdaScript
            ? try EditorScriptableObjectCatalogLoader.load(project: metadata, at: root, fileManager: fileManager) : nil
        try Task.checkCancellation()
        await onPhase(.document)
        let sessionURL = root.appendingPathComponent(".ada/workspace/editor-session.json")
        let saved = (try? Data(contentsOf: sessionURL)).flatMap { try? JSONDecoder().decode(EditorDocumentSession.self, from: $0) }
        let runtimeScene = metadata.build.system.isAdaScript ? metadata.runtime.entry.scene : nil
        let candidates = [saved?.relativePath, runtimeScene, metadata.editor.startupScene, "Assets/Scenes/Main.ascn"]
            .compactMap { $0 }
        let item = candidates.lazy.compactMap { path in items.first { !$0.isFolder && $0.relativePath == path } }.first
            ?? items.first { $0.kind == .scene }
        let document = item.map { EditorViewModel.document(for: $0) }
        try Task.checkCancellation()
        return EditorProjectStartupData(metadata: metadata, items: items, scriptSupport: support,
                                        restoredItem: item, restoredDocument: document, savedDocumentPath: saved?.relativePath)
    }
}

@MainActor
@Observable
final class EditorProjectLoadingModel {
    var phase = EditorProjectLoadingPhase.settings
    var errorMessage: String?
    var viewModel: EditorViewModel?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    func retry(project: EditorProjectReference) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in await self?.load(project: project) }
    }

    func cancel() {
        generation += 1
        retryTask?.cancel()
        retryTask = nil
    }

    func load(project: EditorProjectReference) async {
        guard viewModel == nil else { return }
        generation += 1
        let request = generation
        errorMessage = nil
        do {
            let data = try await EditorProjectStartupLoader.prepare(project: project) { [weak self] phase in
                await self?.update(phase: phase, generation: request)
            }
            try Task.checkCancellation()
            guard generation == request else { return }
            phase = .workspace
            await Task.yield()
            try Task.checkCancellation()
            guard generation == request else { return }
            viewModel = EditorViewModel(project: project, startupData: data)
        } catch is CancellationError {
            // Closing/replacing a project must never install its old workspace.
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func update(phase: EditorProjectLoadingPhase, generation request: Int) {
        guard generation == request, !Task.isCancelled else { return }
        self.phase = phase
    }
}

/// The initial window is cheap to construct and can draw before project I/O begins.
struct EditorView: View {
    let project: EditorProjectReference?
    let usesNativeOrnaments: Bool
    private let suppliedViewModel: EditorViewModel?
    @State private var loading = EditorProjectLoadingModel()

    init(project: EditorProjectReference?, viewModel: EditorViewModel? = nil, usesNativeOrnaments: Bool = false) {
        self.project = project
        self.suppliedViewModel = viewModel
        self.usesNativeOrnaments = usesNativeOrnaments
    }

    var body: some View {
        ZStack {
            if let viewModel = suppliedViewModel ?? loading.viewModel {
                EditorWindowContentView(project: project, viewModel: viewModel, usesNativeOrnaments: usesNativeOrnaments)
            } else if let project {
                EditorProjectLoadingView(project: project, model: loading)
            } else {
                EditorWindowContentView(project: nil, usesNativeOrnaments: usesNativeOrnaments)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if suppliedViewModel == nil, let project { await loading.load(project: project) }
        }
        .onDisappear { loading.cancel() }
    }
}

struct EditorProjectLoadingView: View {
    let project: EditorProjectReference
    let model: EditorProjectLoadingModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Text(L10n.text("Opening \(project.name)"))
                .font(.system(size: 22))
                .foregroundColor(theme.editorColors.text)
                .lineLimit(2)
            Text(model.errorMessage ?? L10n.tr(model.phase.titleKey))
                .font(.system(size: 13))
                .foregroundColor(theme.editorColors.muted)
                .accessibilityIdentifier("AdaEditor.ProjectLoading.Phase")
            EditorLoadingProgressBar(fractionCompleted: model.phase.fractionCompleted, width: 340)
            if model.errorMessage != nil {
                Button(L10n.text("Retry")) { model.retry(project: project) }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.ProjectLoading")
        .theme(.adaEditor)
    }
}

struct EditorLoadingProgressBar: View {
    let fractionCompleted: Float?
    var width: Float = 260
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(anchor: .leading) {
            RoundedRectangleShape(cornerRadius: 3)
                .fill(theme.editorColors.border)
                .frame(width: width, height: 6)
            if let fractionCompleted {
                RoundedRectangleShape(cornerRadius: 3)
                    .fill(theme.editorColors.blue)
                    .frame(width: width * min(1, max(0, fractionCompleted)), height: 6)
                    .accessibilityIdentifier("AdaEditor.LoadingProgress.Fill")
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2)
                    RoundedRectangleShape(cornerRadius: 3)
                        .fill(theme.editorColors.blue)
                        .frame(width: width * 0.3, height: 6)
                        .offset(x: width * 1.3 * phase - width * 0.3)
                }
                .frame(width: width, height: 6, alignment: .leading)
                .mask(RectangleShape())
            }
        }
        .frame(width: width, height: 6)
        .accessibilityIdentifier("AdaEditor.LoadingProgress.Bar")
    }
}
