@_spi(AdaEngine) import AdaEngine

/// Own the resize state beside the text editor so the transcript does not rebuild on drag.
struct EditorAgentPromptEditor: View {
    private let viewModel: EditorAgentViewModel?
    private let text: Binding<String>
    private let placeholder: String
    private let promptIdentifier: String
    private let resizeIdentifier: String
    private let minimumHeight: Float
    private let allowsResize: Bool
    @State private var composerHeight: Float
    @State private var composerDragStart: Float?
    @Environment(\.theme) private var theme

    @MainActor
    init(viewModel: EditorAgentViewModel) {
        self.viewModel = viewModel
        self.text = viewModel.promptBinding
        self.placeholder = "Ask the agent. Use / for commands, @ for context."
        self.promptIdentifier = "AdaEditor.Agent.Prompt"
        self.resizeIdentifier = "AdaEditor.Agent.ResizeComposer"
        self.minimumHeight = 64
        self.allowsResize = true
        self._composerHeight = State(initialValue: 104)
    }

    @MainActor
    init(text: Binding<String>, placeholder: String, initialHeight: Float = 128, promptIdentifier: String) {
        self.viewModel = nil
        self.text = text
        self.placeholder = placeholder
        self.promptIdentifier = promptIdentifier
        self.resizeIdentifier = "AdaEditor.Mobile.ResizeComposer"
        self.minimumHeight = 120
        self.allowsResize = false
        self._composerHeight = State(initialValue: min(320, max(120, initialHeight)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if allowsResize {
                ZStack {
                    RoundedRectangleShape(cornerRadius: 2)
                        .fill(theme.editorColors.muted.opacity(0.6))
                        .frame(width: 28, height: 3)
                    EditorResizeHandle(axis: .vertical) { translation in
                        let start = composerDragStart ?? composerHeight
                        composerDragStart = start
                        composerHeight = min(320, max(minimumHeight, start - translation.height))
                    } onResizeEnded: {
                        composerDragStart = nil
                    }
                }
                .frame(height: 10)
                .accessibilityIdentifier(resizeIdentifier)
            }

            TextEditor(
                placeholder,
                text: text,
                sourceInteraction: sourceInteraction,
                showsLineNumbers: false,
                showsScrollIndicators: viewModel != nil
            )
            .font(.system(size: 14))
            .foregroundColor(theme.editorColors.text)
            .frame(height: composerHeight)
            .frame(minWidth: 0, maxWidth: .infinity)
            .textEditorColors(composerTextEditorColors)
            .accessibilityIdentifier(promptIdentifier)
        }
    }

    private var sourceInteraction: TextEditorSourceInteraction? {
        guard let viewModel else { return nil }
        return TextEditorSourceInteraction(
            focusedRange: viewModel.promptCompletionFocus,
            onCaretChange: viewModel.updatePromptCaret,
            onRequestCompletion: { _, _ in viewModel.dismissCompletions() },
            onMoveCompletionSelection: viewModel.moveCompletionSelection,
            onAcceptCompletion: viewModel.submitPromptFromKeyboard
        )
    }

    private var composerTextEditorColors: TextEditorColors {
        TextEditorColors(
            background: theme.editorColors.surface,
            border: Color.clear,
            focusedBorder: Color.clear,
            gutter: Color.clear,
            gutterRule: Color.clear,
            currentLineBackground: Color.clear,
            selection: theme.editorColors.blue.opacity(0.24)
        )
    }
}
