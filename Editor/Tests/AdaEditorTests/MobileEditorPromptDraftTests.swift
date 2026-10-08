@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math
import Observation
import Synchronization
import Testing

@testable import AdaEditor

@MainActor
struct MobileEditorPromptDraftTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "PromptTests")))
        }
    }

    @Test("Passing the draft binding does not subscribe navigation to text changes")
    func bindingCreationDoesNotObserveText() {
        let draft = MobileEditorPromptDraft()
        let invalidated = Mutex(false)
        let binding = withObservationTracking {
            draft.binding
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        binding.wrappedValue = "A prompt"
        #expect(draft.text == "A prompt")
        #expect(!invalidated.withLock { $0 })
    }

    @Test("Typing updates the observed prompt subtree without rebuilding its root")
    func typingKeepsRootStable() async throws {
        let draft = MobileEditorPromptDraft()
        let counter = PromptBuildCounter()
        let container = UIContainerView(rootView: PromptNavigationFixture(draft: draft, counter: counter))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 240)
        container.layoutSubviews()
        for _ in 0..<4 { await Task.yield() }
        let rootBuilds = counter.root
        for character in "Hello Привет 👋" {
            container.onTextInputEvent(TextInputEvent(window: .empty, text: String(character), action: .insert, time: 0))
            for _ in 0..<4 { await Task.yield() }
            container.layoutSubviews()
        }
        #expect(draft.text == "Hello Привет 👋")
        #expect(counter.root == rootBuilds)
        #expect(counter.prompt > 1)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("send")).count == 1)
    }
}

@MainActor
private final class PromptBuildCounter {
    var root = 0
    var prompt = 0
}

private struct PromptNavigationFixture: View {
    let draft: MobileEditorPromptDraft
    let counter: PromptBuildCounter

    var body: some View {
        counter.root += 1
        return VStack {
            Text("Navigation")
        }
        .fullScreenCover(isPresented: .constant(true), transition: .opacity) {
            PromptInputFixture(text: draft.binding, counter: counter)
        }
        .fullScreenCover(isPresented: .constant(false)) { Text("Voice") }
        .fullScreenCover(isPresented: .constant(false)) { Text("Preview") }
    }
}

private struct PromptInputFixture: View {
    @Binding var text: String
    let counter: PromptBuildCounter

    var body: some View {
        counter.prompt += 1
        return VStack {
            TextEditor(text: _text, showsLineNumbers: false, wrapsLines: true)
                .textEditorAutofocus()
            if !text.isEmpty { Button("Send") {}.accessibilityIdentifier("send") }
        }
    }
}
