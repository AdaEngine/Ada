@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("Ada Script previews")
struct AdaScriptPreviewTests {
    @Test("disabled preview stays hidden until explicitly shown")
    @MainActor
    func disabledPreviewStaysHiddenUntilShown() {
        let source = "@previewable @view class HUDView { func body() { Text(\"Preview\"); } }"
        let document = EditorTextDocument(
            id: "hud",
            title: "HUD.ada",
            relativePath: "Sources/HUD.ada",
            language: .ada,
            content: source
        )
        let workbench = EditorWorkbenchViewModel(
            activeEditorTab: document.title,
            openDocuments: [.text(document)],
            activeDocumentID: document.id
        )
        let viewModel = EditorViewModel(workbench: workbench)

        viewModel.hidePreview()
        viewModel.refreshPreviewForActiveDocument()

        #expect(!workbench.isPreviewEnabled)
        guard case .hidden = workbench.previewStatus else {
            Issue.record("Disabled Preview should stay hidden during refresh")
            return
        }
        #expect(viewModel.previewTask == nil)

        viewModel.showPreview()

        #expect(workbench.isPreviewEnabled)
        guard case .unavailable = workbench.previewStatus else {
            Issue.record("Showing Preview should resume preview discovery")
            return
        }
    }

    @Test("successful autosave swaps preview and failed compilation retains the last working view")
    @MainActor
    func autosavePublishesOnlySuccessfulPreview() async throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("AdaEditorAdaScriptAutoPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectURL) }
        let sourcesURL = projectURL.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourcesURL, withIntermediateDirectories: true)

        let initialSource = "@previewable @view class HUDView { func body() { Text(\"Initial\"); } }"
        let sourceURL = sourcesURL.appendingPathComponent("HUD.ada", isDirectory: false)
        try initialSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        try ProjectSystem.saveProject(
            ProjectSystem.defaultProject(projectName: "Game", buildSystem: .adaScript),
            at: projectURL
        )
        let document = EditorTextDocument(
            id: "hud",
            title: "HUD.ada",
            relativePath: "Sources/HUD.ada",
            absolutePath: sourceURL.path,
            language: .ada,
            content: initialSource,
            lastSavedContent: initialSource
        )
        let workbench = EditorWorkbenchViewModel(
            activeEditorTab: document.title,
            openDocuments: [.text(document)],
            activeDocumentID: document.id
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: projectURL.path),
            workbench: workbench,
            autosaveDelay: .milliseconds(1)
        )

        viewModel.refreshPreviewForActiveDocument()
        let initialView = try await waitForLoadedPreview(in: workbench)

        let updatedSource = "@previewable @view class HUDView { func body() { Text(\"Updated\"); } }"
        workbench.textDocumentBinding(documentID: document.id).wrappedValue = updatedSource
        let updatedView = try await waitForLoadedPreview(in: workbench, replacing: initialView)
        #expect(updatedView !== initialView)

        workbench.textDocumentBinding(documentID: document.id).wrappedValue = "@previewable @view class HUDView { func body() { Text( }"
        for _ in 0..<200 {
            if case let .failed(_, message, _) = workbench.previewStatus {
                #expect(message.contains("failed"))
                #expect(workbench.loadedPreview?.view === updatedView)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        Issue.record("AdaEditor did not report the invalid automatic preview build")
    }

    @Test("editor view model loads a selected Ada Script preview")
    @MainActor
    func editorViewModelLoadsPreview() async throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("AdaEditorAdaScriptPreviewIntegration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectURL) }
        let sourceRoot = projectURL.appendingPathComponent("Sources/Game/Views", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = "@previewable(title: \"HUD Preview\") @view class HUDView { func body() { Text(\"Preview\"); } }"
        let sourceURL = sourceRoot.appendingPathComponent("HUD.ada")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let document = EditorTextDocument(
            id: "hud",
            title: "HUD.ada",
            relativePath: "Sources/Game/Views/HUD.ada",
            absolutePath: sourceURL.path,
            language: .ada,
            content: source,
            errorMessage: nil
        )
        let workbench = EditorWorkbenchViewModel()
        workbench.open(.text(document))
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: projectURL.path),
            workbench: workbench,
            packageModel: packageModel()
        )

        viewModel.refreshPreviewForActiveDocument()
        for _ in 0..<100 {
            if case let .loaded(declaration, _) = workbench.previewStatus {
                #expect(declaration.id == "HUDView")
                #expect(declaration.title == "HUD Preview")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if case let .failed(_, message, _) = workbench.previewStatus {
            Issue.record("AdaEditor preview failed: \(message) \(viewModel.outputLines.map(\.text).joined(separator: " | "))")
        } else {
            Issue.record("AdaEditor did not load the Ada Script preview")
        }
    }

    @Test("scanner finds view declarations")
    func scannerFindsViews() {
        let declarations = EditorPreviewScanner.declarations(
            in: """
                @previewable(title: "HUD Preview")
                @view(id: "game.hud", title: "HUD")
                class HUDView {
                    func body() { Text("Score"); }
                }

                @view
                class RuntimeOnlyView {
                    func body() { Text("Hidden"); }
                }

                @system
                class UpdateSystem {
                    func update(context) {}
                }
                """,
            language: .ada
        )

        #expect(
            declarations == [
                EditorPreviewDeclaration(
                    id: "game.hud",
                    title: "HUD Preview",
                    typeName: "HUDView",
                    line: 3,
                    kind: .adaScript
                )
            ]
        )
    }

    @Test("builder collects target sources and keeps unsaved content")
    func builderCollectsTargetSources() async throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("AdaEditorAdaScriptPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectURL) }

        let sourceRoot = projectURL.appendingPathComponent("Sources/Game", isDirectory: true)
        let viewsRoot = sourceRoot.appendingPathComponent("Views", isDirectory: true)
        try fileManager.createDirectory(at: viewsRoot, withIntermediateDirectories: true)
        let activeURL = viewsRoot.appendingPathComponent("HUD.ada")
        try "stale".write(to: activeURL, atomically: true, encoding: .utf8)
        try "func helper() { return 7; }"
            .write(
                to: sourceRoot.appendingPathComponent("Shared.ada"),
                atomically: true,
                encoding: .utf8
            )

        let model = packageModel()
        let content = "@previewable @view class HUDView { func body() { Text(\"Unsaved\"); } }"
        let document = EditorTextDocument(
            id: "hud",
            title: "HUD.ada",
            relativePath: "Sources/Game/Views/HUD.ada",
            absolutePath: activeURL.path,
            language: .ada,
            content: content,
            errorMessage: nil
        )
        let declaration = EditorPreviewDeclaration(
            id: "HUDView",
            title: "HUDView",
            typeName: "HUDView",
            line: 1,
            kind: .adaScript
        )

        let artifact = try await EditorAdaScriptPreviewBuilder()
            .build(
                EditorPreviewBuildRequest(
                    projectURL: projectURL,
                    document: document,
                    packageModel: model,
                    declaration: declaration
                )
            )

        #expect(artifact.identifier == "HUDView")
        #expect(artifact.sources.map(\.path) == ["Shared.ada", "Views/HUD.ada"])
        #expect(artifact.sources.last?.source == content)
    }

    private func packageModel() -> SwiftPackageModel {
        SwiftPackageModel(
            name: "Game",
            products: [],
            targets: [
                SwiftPackageTarget(
                    name: "Game",
                    type: "executable",
                    path: "Sources/Game",
                    sources: ["Views/HUD.ada", "Shared.ada"],
                    targetDependencies: [],
                    productDependencies: ["AdaEngine"]
                )
            ],
            dependencies: []
        )
    }

    @MainActor
    private func waitForLoadedPreview(
        in workbench: EditorWorkbenchViewModel,
        replacing previousView: UIView? = nil
    ) async throws -> UIView {
        for _ in 0..<200 {
            if case let .loaded(_, view) = workbench.previewStatus,
                previousView == nil || view !== previousView {
                return view
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw EditorPreviewBuildFailure(message: "Timed out waiting for a loaded preview.")
    }
}
