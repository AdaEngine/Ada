import AdaInput
@testable import AdaPlatform
@_spi(Internal) @testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct TextSelectionHandleTests {
    init() async throws { try Application.prepareForTest() }

    @Test(arguments: [false, true])
    func editorDoubleTapAndHandles(wrapped: Bool) throws {
        let tester = fixture(editor: true, wrapped: wrapped)
        let node = try #require(tester.containerView.viewTree.rootNode.uiCollectNodes(where: { $0 is TextEditorViewNode }).first as? TextEditorViewNode)
        let caret = node.selectionCaretRect(at: 8)
        let point = node.selectionTestRootPoint(Point(caret.minX, caret.midY))
        tap(tester, at: point, time: 0)
        tap(tester, at: point, time: 0.15)
        #expect(node.selectedText() == "bravo")
        let handles = try #require(node.touchSelectionHandles())
        let scroll = try #require(node.nearestScrollView())
        let before = scroll.contentOffset
        let endCaret = node.selectionCaretRect(at: 23)
        drag(
            tester,
            from: node.selectionTestRootPoint(handles.end.knobCenter),
            to: node.selectionTestRootPoint(Point(endCaret.minX, endCaret.midY + handles.end.knobCenter.y - handles.end.caret.midY)),
            time: 1
        )
        #expect(node.selectionRange == 6..<23)
        #expect(scroll.contentOffset == before)

        let extended = try #require(node.touchSelectionHandles())
        let startCaret = node.selectionCaretRect(at: 0)
        drag(
            tester,
            from: node.selectionTestRootPoint(extended.start.knobCenter),
            to: node.selectionTestRootPoint(Point(startCaret.minX, startCaret.midY + extended.start.knobCenter.y - extended.start.caret.midY)),
            time: 2
        )
        #expect(node.selectionRange == 0..<23)
        #expect(node.touchSession == nil)
        #expect(node.touchSelectionHandles() != nil)
        tester.sendTextInput("X", time: 3)
        #expect(node.text == "Xail")
        #expect(node.touchSelectionHandles() == nil)
    }

    @Test
    func fieldDoubleTapAndHandles() throws {
        let tester = fixture(editor: false)
        let node = try #require(tester.containerView.viewTree.rootNode.uiCollectNodes(where: { $0 is TextFieldViewNode }).first as? TextFieldViewNode)
        let content = node.textContentRect()
        node.refreshInteractiveTextLayoutIfPossible(size: content.size)
        let point = node.selectionTestRootPoint(Point(content.minX + node.widthForOffset(8, pointSize: 16), content.midY))
        tap(tester, at: point, time: 0)
        tap(tester, at: point, time: 0.15)
        #expect(node.selectedText() == "bravo")
        let handles = try #require(node.touchSelectionHandles())
        let delta = node.widthForOffset(23, pointSize: 16) - node.widthForOffset(11, pointSize: 16)
        drag(
            tester,
            from: node.selectionTestRootPoint(handles.end.knobCenter),
            to: node.selectionTestRootPoint(Point(handles.end.knobCenter.x + delta, handles.end.knobCenter.y)),
            time: 1
        )
        #expect(node.selectionRange == 6..<23)
        let extended = try #require(node.touchSelectionHandles())
        let startDelta = node.widthForOffset(6, pointSize: 16)
        drag(
            tester,
            from: node.selectionTestRootPoint(extended.start.knobCenter),
            to: node.selectionTestRootPoint(Point(extended.start.knobCenter.x - startDelta, extended.start.knobCenter.y)),
            time: 2
        )
        #expect(node.selectionRange == 0..<23)
        tester.sendTextInput("X", time: 3)
        #expect(node.text == "Xail")
        #expect(node.touchSelectionHandles() == nil)
    }

    @Test
    func doubleTapCanContinueDragging() throws {
        let tester = fixture(editor: true)
        let node = try #require(tester.containerView.viewTree.rootNode.uiCollectNodes(where: { $0 is TextEditorViewNode }).first as? TextEditorViewNode)
        let caret = node.selectionCaretRect(at: 8)
        let point = node.selectionTestRootPoint(Point(caret.minX, caret.midY))
        tap(tester, at: point, time: 0)
        let contact = RID()
        touch(tester, point, .began, 0.15, contact)
        #expect(node.selectedText() == "bravo")
        let endCaret = node.selectionCaretRect(at: 23)
        let end = node.selectionTestRootPoint(Point(endCaret.minX, endCaret.midY))
        touch(tester, end, .moved, 0.2, contact)
        touch(tester, end, .ended, 0.25, contact)
        #expect(node.selectionRange == 6..<23)
    }

    @Test
    func cancelledHandleAndOtherFingerPreserveSelection() throws {
        let tester = fixture(editor: true)
        let node = try #require(tester.containerView.viewTree.rootNode.uiCollectNodes(where: { $0 is TextEditorViewNode }).first as? TextEditorViewNode)
        let caret = node.selectionCaretRect(at: 8)
        let point = node.selectionTestRootPoint(Point(caret.minX, caret.midY))
        tap(tester, at: point, time: 0)
        tap(tester, at: point, time: 0.15)
        let handles = try #require(node.touchSelectionHandles())
        let grip = node.selectionTestRootPoint(handles.start.knobCenter)
        let contact = RID()
        touch(tester, grip, .began, 1, contact)
        let other = RID()
        touch(tester, point, .began, 1.01, other)
        touch(tester, point, .ended, 1.02, other)
        touch(tester, grip, .cancelled, 1.1, contact)
        #expect(node.selectionRange == 6..<11)
        #expect(node.touchSession == nil)
        #expect(node.touchSelectionHandles() != nil)
        tester.sendMouseEvent(at: point, phase: .began, time: 2)
        #expect(node.touchSelectionHandles() == nil)
    }

    @Test
    func handlesFollowWrappedRowsAndScrolling() throws {
        let tester = fixture(editor: true, wrapped: true, text: String(repeating: "alpha bravo charlie delta ", count: 40))
        let node = try #require(tester.containerView.viewTree.rootNode.uiCollectNodes(where: { $0 is TextEditorViewNode }).first as? TextEditorViewNode)
        tester.containerView.requestFocus(for: node)
        node.showsTouchSelectionHandles = true
        let rows = node.wrappedRows()
        node.selectionAnchor = 6
        node.selectionHead = rows[7].line.startOffset + 2
        node.ensureCaretVisibleIfNeeded()
        let handles = try #require(node.touchSelectionHandles())
        #expect(handles.end.caret.minY > handles.start.caret.minY)
        let scroll = try #require(node.nearestScrollView())
        #expect(scroll.contentOffset.y > 0)
        let endPoint = node.selectionTestRootPoint(handles.end.knobCenter)
        let contact = RID()
        touch(tester, endPoint, .began, 1, contact)
        #expect(node.touchSession?.handleDrag != nil)
        touch(tester, endPoint, .ended, 1.1, contact)
        #expect(node.selectionHead == rows[7].line.startOffset + 2)
    }

    @Test
    func handlesCannotCrossOrCollapse() {
        let handle = TextSelectionHandle(edge: .start, caret: Rect(x: 10, y: 8, width: 3, height: 20))
        let drag = TextSelectionHandleDrag(handle: handle, range: 6..<11, point: handle.knobCenter)
        #expect(drag.movingOffset(30, textCount: 40) == 10)
        #expect(drag.movingOffset(-10, textCount: 40) == 0)
        #expect(drag.caretPoint(for: handle.knobCenter) == Point(handle.caret.minX, handle.caret.midY))
    }

    @Test(arguments: [false, true])
    func platformDoubleTapSurvivesJitter(editor: Bool) throws {
        let tester = fixture(editor: editor)
        let root = tester.containerView.viewTree.rootNode
        let node = try #require(root.uiCollectNodes(where: { $0 is TextEditorViewNode || $0 is TextFieldViewNode }).first)
        let local: Point
        if let editorNode = node as? TextEditorViewNode {
            let caret = editorNode.selectionCaretRect(at: 8)
            local = Point(caret.minX, caret.midY)
        } else {
            let field = try #require(node as? TextFieldViewNode)
            let content = field.textContentRect()
            field.refreshInteractiveTextLayoutIfPossible(size: content.size)
            local = Point(content.minX + field.widthForOffset(8, pointSize: 16), content.midY)
        }
        let point = node.selectionTestRootPoint(local)
        tap(tester, at: point, time: 0)
        let contact = RID()
        // The platform's gesture interval is allowed to exceed our synthetic fallback.
        touch(tester, point, .began, 1, contact, tapCount: 2)
        let jitter = Point(point.x + 2, point.y + 1)
        touch(tester, jitter, .moved, 1.02, contact, tapCount: 2)
        touch(tester, jitter, .ended, 1.04, contact, tapCount: 2)
        if let editorNode = node as? TextEditorViewNode {
            #expect(editorNode.selectedText() == "bravo")
            #expect(editorNode.touchSelectionHandles() != nil)
        } else {
            let field = try #require(node as? TextFieldViewNode)
            #expect(field.selectedText() == "bravo")
            #expect(field.touchSelectionHandles() != nil)
        }
    }

    private func fixture(editor: Bool, wrapped: Bool = false, text: String? = nil) -> ViewTester<SelectionFixture> {
        ViewTester(rootView: SelectionFixture(editor: editor, wrapped: wrapped, text: text ?? (editor ? "alpha bravo charlie 👨‍👩‍👧‍👦\ntail" : "alpha bravo charlie 👨‍👩‍👧‍👦 tail")))
            .setSize(Size(width: 400, height: 220)).performLayout()
    }

    private func tap(_ tester: ViewTester<SelectionFixture>, at point: Point, time: AdaUtils.TimeInterval) {
        let contact = RID()
        touch(tester, point, .began, time, contact)
        touch(tester, point, .ended, time + 0.03, contact)
    }

    private func drag(_ tester: ViewTester<SelectionFixture>, from start: Point, to end: Point, time: AdaUtils.TimeInterval) {
        let contact = RID()
        touch(tester, start, .began, time, contact)
        touch(tester, end, .moved, time + 0.1, contact)
        touch(tester, end, .ended, time + 0.2, contact)
    }

    private func touch(_ tester: ViewTester<SelectionFixture>, _ point: Point, _ phase: TouchEvent.Phase, _ time: AdaUtils.TimeInterval, _ contact: RID, tapCount: Int = 1) {
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: phase, time: time, contactID: contact, tapCount: tapCount)])
    }
}

private struct SelectionFixture: View {
    let editor: Bool
    let wrapped: Bool
    let text: String

    var body: some View {
        if editor {
            TextEditor(text: .constant(text), showsLineNumbers: false, wrapsLines: wrapped)
                .font(.system(size: 16)).frame(width: 320, height: 160)
        } else {
            TextField("", text: .constant(text)).font(.system(size: 16)).frame(width: 320, height: 44)
        }
    }
}

@MainActor
private extension ViewNode {
    func selectionTestRootPoint(_ point: Point) -> Point {
        let origin = visualAbsoluteFrame().origin
        return Point(origin.x + point.x, origin.y + point.y)
    }
}
