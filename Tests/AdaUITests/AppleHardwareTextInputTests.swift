import AdaInput
@testable import AdaPlatform
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@Suite("Apple hardware text input")
@MainActor
struct AppleHardwareTextInputTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test("printable hardware keys emit text input")
    func printableKeyProducesInsertPayload() {
        let payload = AppleHardwareTextInput.payload(
            keyCode: .a,
            modifiers: [.shift],
            characters: "A"
        )

        #expect(payload == AppleHardwareTextInput.Payload(text: "A", action: .insert))
    }

    @Test("hardware backspace emits delete input")
    func backspaceProducesDeletePayload() {
        let payload = AppleHardwareTextInput.payload(
            keyCode: .backspace,
            modifiers: [],
            characters: ""
        )

        #expect(payload == AppleHardwareTextInput.Payload(text: "", action: .deleteBackward))
    }

    @Test("commands and navigation keys do not emit text")
    func commandsDoNotProduceTextPayload() {
        #expect(AppleHardwareTextInput.payload(keyCode: .s, modifiers: [.main], characters: "s") == nil)
        #expect(AppleHardwareTextInput.payload(keyCode: .tab, modifiers: [], characters: "\t") == nil)
        #expect(AppleHardwareTextInput.payload(keyCode: .arrowLeft, modifiers: [], characters: "") == nil)
    }

    @Test("hardware payload edits the focused text editor")
    func hardwarePayloadEditsFocusedTextEditor() throws {
        final class Model {
            var text = ""
        }

        let model = Model()
        let tester = ViewTester {
            TextEditor(text: Binding(get: { model.text }, set: { model.text = $0 }))
                .frame(width: 240, height: 100)
        }
        .setSize(Size(width: 260, height: 120))
        .performLayout()
        tester.sendMouseEvent(at: Point(100, 28), phase: .began)

        let payload = try #require(
            AppleHardwareTextInput.payload(keyCode: .a, modifiers: [], characters: "a")
        )
        tester.containerView.onTextInputEvent(
            TextInputEvent(
                window: .empty,
                text: payload.text,
                action: payload.action,
                time: 0
            )
        )

        #expect(model.text == "a")
    }
}
