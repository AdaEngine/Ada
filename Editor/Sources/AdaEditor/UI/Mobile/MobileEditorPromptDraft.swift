@_spi(AdaEngine) import AdaEngine
import Observation

/// Typing updates only views that read the draft, rather than the app's navigation state.
@MainActor
@Observable
final class MobileEditorPromptDraft {
    var text = ""

    var binding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0 })
    }
}
