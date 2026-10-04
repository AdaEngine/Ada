@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor split screen", .serialized)
@MainActor
struct EditorWorkbenchSplitTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "EditorWorkbenchSplitTests")))
        }
    }

    @Test("split selections remain independent and newly opened files follow the focused group")
    func independentSelections() {
        let documents = makeDocuments()
        let workbench = EditorWorkbenchViewModel(openDocuments: documents, activeDocumentID: documents[0].id)
        workbench.splitDocument(id: documents[1].id)
        #expect(workbench.selectedDocument(in: .primary)?.id == documents[0].id)
        #expect(workbench.selectedDocument(in: .secondary)?.id == documents[1].id)
        workbench.selectDocument(id: documents[2].id)
        #expect(workbench.selectedDocument(in: .secondary)?.id == documents[1].id)
        workbench.selectDocument(id: documents[1].id)
        let newDocument = EditorWorkbenchDocument.text(EditorTextDocument(id: "new", title: "New.ada", relativePath: "New.ada", language: .ada, content: ""))
        workbench.open(newDocument)
        #expect(workbench.pane(for: newDocument.id) == .secondary)
        #expect(workbench.selectedDocument(in: .primary)?.id == documents[2].id)
        #expect(workbench.navigateBack())
        #expect(workbench.activeDocumentID == documents[1].id)
        #expect(workbench.focusedPane == .secondary)
        workbench.mergePanes()
        #expect(!workbench.isSplit)
        #expect(workbench.openDocuments.count == 4)
        #expect(workbench.activeDocumentID == documents[1].id)
    }

    @Test("closing the last split tab collapses the split and failed saves keep both groups")
    func closingSplit() {
        let documents = makeDocuments()
        let workbench = EditorWorkbenchViewModel(openDocuments: documents, activeDocumentID: documents[0].id)
        workbench.splitDocument(id: documents[1].id)
        workbench.updateTextDocument(id: documents[1].id) { $0.isDirty = true }
        workbench.closeDocument(id: documents[1].id)
        #expect(workbench.isSplit)
        #expect(workbench.openDocuments.count == 3)
        workbench.updateTextDocument(id: documents[1].id) { $0.isDirty = false }
        workbench.closeDocument(id: documents[1].id)
        #expect(!workbench.isSplit)
        #expect(workbench.activeDocument != nil)
        workbench.splitDocument(id: documents[2].id)
        workbench.discardDocuments(atOrBelow: "Third.swift")
        #expect(!workbench.isSplit)
        #expect(workbench.activeDocumentID == documents[0].id)
    }

    @Test("closing an active split tab selects another tab from the same group")
    func closeWithinGroup() {
        let documents = makeDocuments()
        let workbench = EditorWorkbenchViewModel(openDocuments: documents, activeDocumentID: documents[0].id)
        workbench.splitDocument(id: documents[1].id)
        workbench.moveDocument(id: documents[2].id, to: .secondary)
        workbench.closeDocument(id: documents[2].id)
        #expect(workbench.isSplit)
        #expect(workbench.activeDocumentID == documents[1].id)
        #expect(workbench.selectedDocument(in: .primary)?.id == documents[0].id)
        workbench.moveDocument(id: documents[1].id, to: .primary)
        #expect(!workbench.isSplit)
    }

    @Test("rendered panes resize and preserve code input and tab actions")
    func renderedSplit() async throws {
        let documents = makeDocuments()
        let workbench = EditorWorkbenchViewModel(openDocuments: documents, activeDocumentID: documents[0].id)
        let container = makeContainer(workbench)
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 500)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        #if os(macOS) || os(Windows) || os(Linux)
            #expect(throws: (any Error).self) {
                try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Files"))
            }
        #endif
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Workbench.Split"))
        await settle(container)
        #if os(macOS) || os(Windows) || os(Linux)
            #expect(throws: (any Error).self) {
                try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Files.secondary"))
            }
        #endif
        let left = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Workbench.Pane.primary")).absoluteFrame
        let right = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Workbench.Pane.secondary")).absoluteFrame
        #expect(left.width > 0 && right.width > 0)
        #expect(left.maxX <= right.minX)
        let point = Point(left.minX + 120, left.minY + 130)
        click(point, in: container)
        #expect(workbench.activeDocumentID == documents[1].id)
        container.onKeyEvent(KeyEvent(window: RID(), keyCode: .enter, modifiers: [], status: .down, time: 0, isRepeated: false))
        #expect(workbench.textDocument(id: documents[1].id)?.content.contains("\n") == true)
        #expect(workbench.textDocument(id: documents[0].id)?.content == "let value = 42")
        await settle(container)
        let handle = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Workbench.Split.Resize")).absoluteFrame
        for (phase, offset) in [(MouseEvent.Phase.began, Float(0)), (.changed, 120), (.ended, 120)] {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(handle.midX + offset, handle.midY), phase: phase, modifierKeys: [], time: 0))
            await settle(container)
        }
        let resized = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Workbench.Pane.primary")).absoluteFrame
        #expect(resized.width > left.width + 80)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Close.\(documents[0].id)"))
        await settle(container)
        #expect(!workbench.isSplit)
        #expect(workbench.openDocuments.count == 2)
    }

    @Test("close others stays within the selected editor group")
    func closeOthersInGroup() {
        let documents = makeDocuments()
        let workbench = EditorWorkbenchViewModel(openDocuments: documents, activeDocumentID: documents[0].id)
        workbench.splitDocument(id: documents[2].id)
        workbench.closeOtherDocuments(keeping: documents[0].id)
        #expect(workbench.openDocuments.map(\.id) == [documents[0].id, documents[2].id])
        #expect(workbench.isSplit)
        #expect(workbench.activeDocumentID == documents[2].id)
    }

    @Test("split size stays usable after a narrow window resize")
    func constrainedResize() {
        let state = EditorWorkbenchResizeState()
        state.resize(translation: 900, availableWidth: 1000)
        #expect(state.fraction < 1)
        state.endDrag()
        state.resize(translation: -900, availableWidth: 300)
        #expect(state.fraction == 0.5)
    }

    @Test("a split with one document can open a file in the empty left group")
    func openInEmptyPane() {
        let documents = makeDocuments()
        let workbench = EditorWorkbenchViewModel(openDocuments: [documents[0]], activeDocumentID: documents[0].id)
        workbench.splitDocument(id: documents[0].id)
        workbench.focusPane(.primary)
        workbench.open(documents[1])
        #expect(workbench.selectedDocument(in: .primary)?.id == documents[1].id)
        #expect(workbench.selectedDocument(in: .secondary)?.id == documents[0].id)
        #expect(workbench.focusedPane == .primary)
    }

    @Test("code and a real scene occupy separate rendered panes")
    func codeAndScene() async throws {
        let sceneModel = EditorSceneModel.default(projectName: "Split")
        let content = try sceneModel.encodedYAML()
        let scene = EditorWorkbenchDocument.scene(EditorSceneDocument(
            id: "scene:Split",
            title: "Split.ascn",
            relativePath: "Assets/Scenes/Split.ascn",
            absolutePath: nil,
            content: content,
            lastSavedContent: content,
            isReadOnly: false,
            sceneModel: sceneModel,
            errorMessage: nil,
            isDirty: false,
            statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        ))
        let code = makeDocuments()[0]
        let workbench = EditorWorkbenchViewModel(openDocuments: [code, scene], activeDocumentID: code.id)
        workbench.splitDocument(id: scene.id)
        let container = makeContainer(workbench)
        container.frame = Rect(x: 0, y: 0, width: 1200, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let left = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Workbench.Pane.primary")).absoluteFrame
        let right = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneDocument.Split.ascn")).absoluteFrame
        #expect(left.maxX <= right.minX)
        #expect(right.width > 0 && right.height > 0)
        click(Point(left.minX + 120, left.minY + 130), in: container)
        #expect(workbench.activeDocumentID == code.id)
        #expect(workbench.selectedDocument(in: .secondary)?.id == scene.id)
        await settle(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Tab.Select.\(scene.id)"))
        #expect(workbench.activeSceneDocument?.id == scene.id)
        #expect(workbench.selectedDocument(in: .primary)?.id == code.id)
    }

    private func makeDocuments() -> [EditorWorkbenchDocument] {
        ["First.swift", "Second.swift", "Third.swift"].map { title in
            .text(EditorTextDocument(id: "text:\(title)", title: title, relativePath: title, language: .swift, content: "let value = 42"))
        }
    }

    private func click(_ point: Point, in container: UIContainerView<EditorCenterWorkbench>) {
        for phase in [MouseEvent.Phase.began, .ended] {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
        }
    }

    private func settle(_ container: UIContainerView<EditorCenterWorkbench>) async {
        for _ in 0..<3 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
    }

    private func makeContainer(_ workbench: EditorWorkbenchViewModel) -> UIContainerView<EditorCenterWorkbench> {
        UIContainerView(
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
    }
}
