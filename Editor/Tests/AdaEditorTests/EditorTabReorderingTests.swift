@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("Editor tab reordering", .serialized)
@MainActor
struct EditorTabReorderingTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "EditorTabReorderingTests")))
        }
    }

    @Test("moving tabs preserves the active document and navigation history")
    func modelReordersDocuments() {
        let documents = makeDocuments()
        let workbench = EditorWorkbenchViewModel(openDocuments: documents, activeDocumentID: documents[1].id)
        workbench.selectDocument(id: documents[2].id)

        workbench.moveDocument(id: documents[0].id, toIndex: 2)
        #expect(workbench.openDocuments.map(\.id) == [documents[1].id, documents[2].id, documents[0].id])
        #expect(workbench.activeDocumentID == documents[2].id)
        #expect(workbench.navigateBack())
        #expect(workbench.activeDocumentID == documents[1].id)

        workbench.moveDocument(id: documents[0].id, toIndex: 0)
        #expect(workbench.openDocuments.map(\.id) == documents.map(\.id))
        workbench.moveDocument(id: "missing", toIndex: 1)
        workbench.moveDocument(id: documents[0].id, toIndex: 99)
        #expect(workbench.openDocuments.map(\.id) == documents.map(\.id))
    }

    @Test("dragging a tab changes its position in the rendered tab bar")
    func dragReordersTabs() async throws {
        let documents = makeDocuments()
        let workbench = EditorWorkbenchViewModel(openDocuments: documents, activeDocumentID: documents[1].id)
        let container = UIContainerView(
            rootView: EditorCenterWorkbench(
                viewModel: workbench,
                inspectorViewModel: EditorInspectorSidebarViewModel(),
                playModeState: .editing,
                scenePlayRuntime: nil,
                sceneResourceRootURL: nil,
                onPlayScene: nil,
                onStopScene: nil,
                onSceneEntitySelected: nil,
                onSourceHover: nil,
                onGoToDefinition: nil,
                onCompletionPosition: nil,
                onCompletionRequest: nil,
                onApplyCompletion: nil,
                onMoveCompletionSelection: nil,
                onAcceptCompletion: nil,
                onTextSelection: nil,
                onChatSelection: nil,
                sourceContextMenuItems: nil,
                onSelectDocument: nil,
                onRevealDocument: nil,
                onCopyDocumentPath: nil,
                onSelectPreview: nil,
                onRebuildPreview: nil,
                onHidePreview: nil,
                onShowPreviewBuildOutput: nil
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 800, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let first = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Select.\(documents[0].id)")).absoluteFrame
        let third = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Select.\(documents[2].id)")).absoluteFrame
        let start = Point(first.midX, first.midY)
        let end = Point(third.midX, third.midY)
        for (phase, point) in [(MouseEvent.Phase.began, start), (.changed, end), (.ended, end)] {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
            for _ in 0..<3 {
                await Task.yield()
                container.update(1.0 / 60.0)
                container.layoutIfNeeded()
            }
        }

        #expect(workbench.openDocuments.map(\.id) == [documents[1].id, documents[2].id, documents[0].id])
        #expect(workbench.activeDocumentID == documents[1].id)
        let moved = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Select.\(documents[0].id)")).absoluteFrame
        let middle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Select.\(documents[2].id)")).absoluteFrame
        #expect(moved.minX > middle.minX)

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Select.\(documents[0].id)"))
        #expect(workbench.activeDocumentID == documents[0].id)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Close.\(documents[0].id)"))
        #expect(workbench.openDocuments.map(\.id) == [documents[1].id, documents[2].id])
    }

    private func makeDocuments() -> [EditorWorkbenchDocument] {
        ["First.swift", "Second.swift", "Third.swift"].map { title in
            .text(EditorTextDocument(id: "text:\(title)", title: title, relativePath: title, language: .swift, content: ""))
        }
    }
}
