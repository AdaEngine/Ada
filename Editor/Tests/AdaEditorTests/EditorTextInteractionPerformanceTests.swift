@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaInput
@_spi(Internal) @testable import AdaUI
import Math
import Observation
import Synchronization
import Testing

@testable import AdaEditor

@MainActor
@Suite("Text interaction performance", .serialized)
struct EditorTextInteractionPerformanceTests {
    @Test("Selection snapshots stay current without publishing document edits")
    func selectionSnapshots() throws {
        let model = makeModel()
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.openDocuments
            _ = model.activeDocument
        } onChange: {
            changed.withLock { $0 = true }
        }
        var documentChanges = 0
        var edits = 0
        model.setActiveDocumentChangedHandler { documentChanges += 1 }
        model.setDocumentEditedHandler { _ in edits += 1 }
        let range = EditorSourceRange(start: .init(line: 0, character: 4), end: .init(line: 0, character: 9))
        model.updateTextSelection(documentID: "text", range: range, text: "value")
        model.updateTextSelection(documentID: "text", range: range, text: "value")
        #expect(!changed.withLock { $0 })
        #expect(documentChanges == 0)
        #expect(edits == 0)
        #expect(model.textDocument(id: "text")?.selectionRange == range)
        guard case let .text(active)? = model.activeDocument else {
            Issue.record("Missing active text document")
            return
        }
        #expect(active.selectedText == "value")
        #expect(!active.isDirty)
        #expect(model.presentFileSearch())
        #expect(model.textDocument(id: "text")?.fileSearch.query == "value")
        model.updateTextSelection(documentID: "text", range: nil, text: "")
        #expect(model.textDocument(id: "text")?.selectedText == nil)
        model.closeDocument(id: "text")
        model.open(.text(active))
        // Reopening uses the supplied document's selection, not a stale cache.
        #expect(model.textDocument(id: "text")?.selectedText == "value")
    }

    @Test("Dragging in the mounted code view does not rebuild the workspace")
    func selectionAvoidsRebuilds() throws {
        prepareRenderer()
        let model = makeModel()
        let container = UIContainerView(rootView: PerformanceCodeView(model: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 700, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        _ = try container.uiFocusNode(matching: .runtimeID(String(UInt(bitPattern: node.id), radix: 16)))
        node.selectionAnchor = 0
        node.selectionHead = 1
        node.notifyCaretChange(requestsCompletion: false)
        container.layoutIfNeeded()
        UILayoutDebugCounters.isEnabled = true
        UILayoutDebugCounters.reset()
        defer { UILayoutDebugCounters.isEnabled = false }
        for offset in 2...30 {
            node.selectionHead = offset
            node.notifyCaretChange(requestsCompletion: false)
            container.layoutIfNeeded()
        }
        #expect(UILayoutDebugCounters.snapshot.rebuilds == 0)
        #expect(model.textDocument(id: "text")?.selectedText == node.selectedText())
        #expect(model.textDocument(id: "text")?.isDirty == false)
    }

    @Test("Only text-selection moves coalesce, retaining modifiers, keys, windows and release")
    func batchesCapturedTextSelection() throws {
        prepareRenderer()
        let manager = TextInputWindowManager()
        let frame = Rect(x: 0, y: 0, width: 700, height: 300)
        let window = UIWindow(frame: frame, configuration: .init(frame: frame), windowManager: manager)
        let other = UIWindow(frame: frame, configuration: .init(frame: frame), windowManager: manager)
        let model = makeModel()
        let container = UIContainerView(rootView: PerformanceCodeView(model: model).theme(.adaEditor))
        container.frame = frame
        container.bounds.size = frame.size
        window.addSubview(container)
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        let original = node.sourceInteraction?.onSelectionChange
        var callbacks = 0
        node.sourceInteraction?.onSelectionChange = { range, text in
            callbacks += 1
            original?(range, text)
        }
        func mouse(_ time: Float, x: Float, phase: MouseEvent.Phase = .changed, modifiers: KeyModifier = []) -> MouseEvent {
            MouseEvent(window: window.id, button: .left, mousePosition: Point(x, 70), phase: phase, modifierKeys: modifiers, time: time)
        }
        let events: [any InputEvent] = [
            mouse(0, x: 120, phase: .began),
            mouse(1, x: 140), mouse(2, x: 160),
            mouse(3, x: 180, modifiers: .shift), mouse(4, x: 200, modifiers: .shift),
            KeyEvent(window: window.id, keyCode: .space, modifiers: [], status: .up, time: 5, isRepeated: false),
            mouse(6, x: 220, modifiers: .shift),
            MouseEvent(window: other.id, button: .none, mousePosition: [10, 10], phase: .changed, modifierKeys: [], time: 7),
            mouse(8, x: 240, modifiers: .shift), mouse(9, x: 260, modifiers: .shift),
            mouse(10, x: 280, phase: .ended)
        ]
        var input = Input(gameControllerEngine: nil)
        events.forEach { input.receiveEvent($0) }
        input.flushPendingEvents()
        window.sendPendingInput(&input)
        #expect(callbacks == 6)
        #expect(!node.isSelectingWithMouse)
        #expect(node.hasSelection)
        #expect(model.textDocument(id: "text")?.selectedText == node.selectedText())
        #expect(input.getInputEvents().map(\.id) == events.map(\.id))
        for event in events where event.window == window.id && event is MouseEvent {
            #expect(input.isScenePickingBlocked(eventID: event.id))
        }
    }

    private func makeModel() -> EditorWorkbenchViewModel {
        let source = "let value = \"Привет 👩🏽‍💻 e\u{301}\"\nlet other = 2\n" + String(repeating: "let item = 3\n", count: 30)
        return EditorWorkbenchViewModel(
            openDocuments: [.text(EditorTextDocument(id: "text", title: "Text.ada", relativePath: "Text.ada", language: .ada, content: source, errorMessage: nil))],
            activeDocumentID: "text"
        )
    }

    private func editorNode(in node: ViewNode) -> TextEditorViewNode? {
        if let editor = node as? TextEditorViewNode { return editor }
        return node.transientEnvironmentChildren.lazy.compactMap { editorNode(in: $0) }.first
    }

    private func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "TextPerformance")))
        }
    }
}

private struct PerformanceCodeView: View {
    let model: EditorWorkbenchViewModel

    var body: some View {
        if case let .text(document)? = model.activeDocument {
            EditorCodeFileView(
                document: document,
                text: model.textDocumentBinding(documentID: document.id),
                fontSize: model.codeFontSize,
                fontFamily: model.codeFontFamily,
                fontWeight: model.codeFontWeight,
                keywordFontWeight: model.keywordFontWeight,
                colorPalette: model.codeColorPalette,
                onSourceHover: nil,
                onGoToDefinition: nil,
                onCompletionPosition: nil,
                onCompletionRequest: nil,
                onApplyCompletion: nil,
                onMoveCompletionSelection: nil,
                onAcceptCompletion: nil,
                onTextSelection: { document, range, text in
                    model.updateTextSelection(documentID: document.id, range: range, text: text)
                },
                onChatSelection: nil,
                sourceContextMenuItems: nil
            )
        }
    }
}

@MainActor
private final class TextInputWindowManager: UIWindowManager {
    override func resizeWindow(_: UIWindow, size _: Size) {}
    override func getScreen(for _: UIWindow) -> Screen? { nil }
    override func setCursorShape(_: Input.CursorShape) {}
}
