import Foundation
import Testing
import AdaInput
import AdaUtils
import Math
@testable import AdaPlatform
@testable import AdaUI

@MainActor
struct TextSelectionTests {
    init() async throws { try Application.prepareForTest() }

    @Test func plainTextRemainsUnfocusableUnlessSelectionIsEnabled() {
        let tester = ViewTester { Text("Read only").frame(width: 220, height: 40) }
            .setSize(Size(width: 240, height: 60)).performLayout()
        let node = tester.click(at: Point(120, 30))
        #expect(node?.canBecomeFocused == false)
    }

    @Test func copyUsesRenderedMarkdownAndKeepsUnicode() throws {
        let tester = ViewTester {
            Text(markdown: "**Привет** 👨‍👩‍👧\n\n- One\n- Two")
                .textSelection(.enabled).frame(width: 260, height: 140)
        }.setSize(Size(width: 280, height: 160)).performLayout()
        let node = try #require(tester.click(at: Point(140, 80)) as? TextViewNode)
        #expect(node.canBecomeFocused)
        tester.sendMouseEvent(at: Point(140, 80), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(140, 80), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.a, modifiers: [.control], time: 1)
        #expect(node.selectedSourceRange != nil)
        tester.sendKeyEvent(.c, modifiers: [.control], time: 2)
        #expect(UIClipboard.getString() == "Привет 👨‍👩‍👧\n\n• One\n• Two")
        tester.sendKeyEvent(.escape, time: 3)
        #expect(node.selectedSourceRange == nil)
    }

    @Test func completionKeyHandlerRunsBeforeSubmit() {
        var submitted = false
        var intercepted = false
        let tester = ViewTester {
            TextField("", text: .constant("/review"), onSubmit: { submitted = true })
                .onKeyPress { event in
                    if event.keyCode == .enter { intercepted = true; return true }
                    return false
                }.frame(width: 240, height: 40)
        }.setSize(Size(width: 260, height: 60)).performLayout()
        tester.sendMouseEvent(at: Point(130, 30), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(130, 30), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.enter, time: 1)
        #expect(intercepted)
        #expect(!submitted)
    }
}
