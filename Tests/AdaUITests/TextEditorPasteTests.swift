import AdaInput
import Math
import Testing
@testable import AdaPlatform
@_spi(Internal) @testable import AdaUI

#if canImport(AppKit) || canImport(UIKit)
@MainActor
@Suite("Text editor rich paste", .serialized)
struct TextEditorPasteTests {
    init() async throws { try Application.prepareForTest() }

    @Test("The real paste key event reaches the attachment handler and preserves text")
    func consumesRichPaste() throws {
        var content = "Keep this text"
        var calls = 0
        let tester = ViewTester {
            AnyView(TextEditor(text: Binding(get: { content }, set: { content = $0 }))
                .onTextEditorPaste { calls += 1; return true }
                .font(.system(size: 12))
                .frame(width: 360, height: 160))
        }.setSize(Size(width: 380, height: 180)).performLayout()
        _ = try #require(tester.sendMouseEvent(at: Point(100, 28), phase: .began) as? TextEditorViewNode)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        tester.sendKeyEvent(.v, modifiers: [.main])
        #expect(calls == 1)
        #expect(content == "Keep this text")
    }
}
#endif
