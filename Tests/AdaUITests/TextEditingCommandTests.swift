import Math
import Testing
@testable import AdaPlatform
@testable import AdaUI

@MainActor
struct TextEditingCommandTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func focusedTextEditorReceivesMenuEditingCommands() {
        final class Model {
            var text = "alpha"
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(text: Binding(get: { model.text }, set: { model.text = $0 }))
                .frame(width: 360, height: 160)
        }
        .setSize(Size(width: 380, height: 180))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 28), phase: .began, time: 0)
        tester.sendMouseEvent(at: Point(100, 28), phase: .ended, time: 0.01)
        #expect(tester.containerView.uiPerformTextEditingCommand(.selectAll))
        tester.sendTextInput("changed", time: 0.02)
        #expect(model.text == "changed")

        #expect(tester.containerView.uiPerformTextEditingCommand(.undo))
        #expect(model.text == "alpha")
        #expect(tester.containerView.uiPerformTextEditingCommand(.redo))
        #expect(model.text == "changed")
    }
}
