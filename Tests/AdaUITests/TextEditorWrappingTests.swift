import AdaInput
@testable import AdaPlatform
import AdaText
@testable import AdaUI
import Math
import Observation
import Testing

@MainActor
struct TextEditorWrappingTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test("Long paragraphs wrap without changing text, and keep the caret inside the viewport")
    func wrapsAndScrollsVertically() throws {
        var text = String(repeating: "Привет 世界 👨‍👩‍👧‍👦 длинный текст ", count: 30)
        let original = text
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }), showsLineNumbers: false, wrapsLines: true)
                .font(.system(size: 16))
                .frame(width: 280, height: 120)
        }.setSize(Size(width: 280, height: 120)).performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(20, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(20, 28), phase: .ended)
        let scroll = try #require(node.nearestScrollView())
        #expect(scroll.axis == [.vertical])
        #expect(node.wrappedRows().count > 10)
        #expect(node.wrappedRows().map(\.line.text).joined() == original)
        node.setSelection(to: text.count)
        node.ensureCaretVisibleIfNeeded()
        #expect(scroll.contentOffset.y > 0)
        #expect(scroll.contentOffset.x == 0)
        #expect(node.caretRect().maxX <= scroll.frame.width)
        #expect(node.caretViewportRect().maxY <= scroll.frame.height)
        tester.sendTextInput("!")
        tester.performLayout()
        #expect(text == original + "!")
        tester.sendKeyEvent(.z, modifiers: [.main])
        #expect(text == original)
    }

    @Test("Hit testing and arrow navigation use wrapped visual rows and preserve source offsets")
    func wrappedCaretNavigation() throws {
        var text = String(repeating: "abcdefghij", count: 12) + "\nTail"
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }), showsLineNumbers: false, wrapsLines: true)
                .font(.system(size: 16))
                .frame(width: 150, height: 300)
        }.setSize(Size(width: 150, height: 300)).performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(20, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(20, 28), phase: .ended)
        let rows = node.wrappedRows()
        #expect(rows.count > 2)
        let second = rows[1]
        let y = node.textRect().minY + node.lineHeight(for: 16) * 1.5
        let offset = node.closestOffset(to: Point(node.textRect().minX, y))
        #expect(offset == second.line.startOffset)
        node.setSelection(to: rows[0].line.startOffset + 2)
        tester.sendKeyEvent(.arrowDown)
        #expect(node.caretOffset == second.line.startOffset + 2)
        tester.sendKeyEvent(.arrowUp, modifiers: [.shift])
        #expect(node.selectionRange == 2..<(second.line.startOffset + 2))
        #expect(node.selectedText() == String(text.dropFirst(2).prefix(second.line.startOffset)))
        node.setSelection(to: second.line.startOffset)
        #expect(node.caretRect().minY == node.textRect().minY + node.lineHeight(for: 16))
    }

    @Test("Resizing reflows paragraphs while preserving text and selection")
    func resizeReflowsText() throws {
        var text = String(repeating: "A long prompt with words ", count: 20)
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }), showsLineNumbers: false, wrapsLines: true)
        }.setSize(Size(width: 180, height: 220)).performLayout()
        let node = try #require(tester.sendMouseEvent(at: Point(20, 28), phase: .began) as? TextEditorViewNode)
        node.selectionAnchor = 5
        node.selectionHead = 40
        let before = node.wrappedRows().count
        tester.setSize(Size(width: 360, height: 220)).performLayout()
        #expect(node.wrappedRows().count < before)
        #expect(node.selectionRange == 5..<40)
        #expect(text == String(repeating: "A long prompt with words ", count: 20))
    }

    @Test("Autofocus uses the editor node and survives content reconciliation")
    func autofocusAfterLayout() async throws {
        var text = ""
        let tester = ViewTester {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }), showsLineNumbers: false, wrapsLines: true)
                .textEditorAutofocus()
                .accessibilityIdentifier("prompt")
                .frame(width: 280, height: 120)
        }.setSize(Size(width: 280, height: 120)).performLayout()
        for _ in 0..<4 { await Task.yield() }
        let node = try #require(tester.containerView.viewTree.rootNode.uiCollectNodes(where: { $0 is TextEditorViewNode }).first as? TextEditorViewNode)
        #expect(node.isFocused)
        tester.sendTextInput("Hello")
        #expect(text == "Hello")
        tester.invalidateContent().performLayout()
        for _ in 0..<4 { await Task.yield() }
        tester.sendTextInput("!")
        #expect(text == "Hello!")
    }

    @Test("An expansion control restores editor focus through a new request ID")
    func controlRestoresFocus() async throws {
        let model = EditorFocusRequestModel()
        let tester = ViewTester { EditorFocusRequestFixture(model: model) }
            .setSize(Size(width: 280, height: 160)).performLayout()
        for _ in 0..<4 { await Task.yield() }
        let node = try #require(tester.containerView.viewTree.rootNode.uiCollectNodes(where: { $0 is TextEditorViewNode }).first as? TextEditorViewNode)
        #expect(node.isFocused)
        tester.sendMouseEvent(at: Point(140, 140), phase: .began)
        tester.sendMouseEvent(at: Point(140, 140), phase: .ended)
        #expect(model.requestID == 1)
        for _ in 0..<4 { await Task.yield() }
        tester.performLayout()
        for _ in 0..<4 { await Task.yield() }
        #expect(node.isFocused)
        tester.sendTextInput("Still editing")
        #expect(model.text == "Still editing")
    }
}

@MainActor @Observable
private final class EditorFocusRequestModel {
    var text = ""
    var requestID = 0
}

private struct EditorFocusRequestFixture: View {
    let model: EditorFocusRequestModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: Binding(get: { model.text }, set: { model.text = $0 }), showsLineNumbers: false, wrapsLines: true)
                .textEditorAutofocus(requestID: model.requestID)
                .frame(width: 280, height: 120)
            Button("Expand") { model.requestID += 1 }
                .frame(width: 280, height: 40)
        }
    }
}
