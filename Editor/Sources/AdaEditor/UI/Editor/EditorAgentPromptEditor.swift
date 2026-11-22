@_spi(AdaEngine) import AdaEngine

/// Own the resize state beside the text editor so the transcript does not rebuild on drag.
struct EditorAgentPromptEditor: View {
    static let minimumDesktopHeight: Float = 58

    private let viewModel: EditorAgentViewModel?
    private let text: Binding<String>
    private let placeholder: String
    private let promptIdentifier: String
    private let resizeIdentifier: String
    private let minimumHeight: Float
    private let allowsResize: Bool
    private let isDocked: Bool
    private let onCaret: ((Rect) -> Void)?
    private let maximumHeight: Float
    private let focusRequest: UInt64
    @State private var composerHeight: Float
    @State private var composerDragStart: Float?
    @Environment(\.theme) private var theme
    @Environment(\.viewProxy) private var viewProxy

    @MainActor
    init(
        viewModel: EditorAgentViewModel,
        isDocked: Bool = false,
        maximumHeight: Float = 320,
        focusRequest: UInt64 = 0,
        onCaret: ((Rect) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.text = viewModel.promptBinding
        self.placeholder = onCaret == nil ? "Ask the agent. Use / for commands, @ for context."
            : L10n.text("Message agent - @ to include context, / to include skills and commands")
        self.promptIdentifier = "AdaEditor.Agent.Prompt"
        self.resizeIdentifier = "AdaEditor.Agent.ResizeComposer"
        self.minimumHeight = onCaret == nil ? 64 : Self.minimumDesktopHeight
        self.allowsResize = true
        self.isDocked = isDocked
        self.onCaret = onCaret
        self.maximumHeight = maximumHeight
        self.focusRequest = focusRequest
        self._composerHeight = State(initialValue: onCaret == nil ? 104 : Self.minimumDesktopHeight)
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
        self.isDocked = false
        self.onCaret = nil
        self.maximumHeight = 320
        self.focusRequest = 0
        self._composerHeight = State(initialValue: min(320, max(120, initialHeight)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if allowsResize {
                ZStack {
                    if onCaret == nil {
                        RoundedRectangleShape(cornerRadius: 2)
                            .fill(theme.editorColors.muted.opacity(0.6))
                            .frame(width: 28, height: 3)
                    }
                    EditorResizeHandle(axis: .vertical) { translation in
                        let start = composerDragStart ?? editorHeight
                        composerDragStart = start
                        composerHeight = min(maximumHeight, max(minimumHeight, start - translation.height))
                    } onResizeEnded: {
                        composerDragStart = nil
                    }
                }
                .frame(height: 10)
                .accessibilityIdentifier(resizeIdentifier)
            }

            if onCaret == nil {
                prompt(in: nil)
            } else {
                GeometryReader { geometry in
                    prompt(in: geometry)
                }
                .frame(height: editorHeight)
            }
        }
        .onChange(of: viewModel?.activeSessionID) { previous, current in
            guard onCaret != nil, previous != nil, current != nil else {
                return
            }
            restoreFocus()
        }
        .onChange(of: focusRequest) { _, _ in restoreFocus() }
    }

    private func restoreFocus() {
        Task { @MainActor in
            await Task.yield()
            viewProxy.focusFirstControl()
        }
    }

    private var editorHeight: Float { min(maximumHeight, max(composerHeight, isDocked ? 70 : minimumHeight)) }

    private func prompt(in geometry: GeometryProxy?) -> some View {
        TextEditor(
            onCaret == nil ? placeholder : "",
            text: text,
            sourceInteraction: sourceInteraction(in: geometry),
            showsLineNumbers: false,
            showsScrollIndicators: viewModel != nil,
            wrapsLines: true
        )
        .font(.system(size: 14))
        .foregroundColor(theme.editorColors.text)
        .accentColor(.white)
        .frame(height: editorHeight)
        .frame(minWidth: 0, maxWidth: .infinity)
        .textEditorColors(composerTextEditorColors)
        .accessibilityIdentifier(promptIdentifier)
        .overlay(anchor: .topLeading) {
            if onCaret != nil, text.wrappedValue.isEmpty {
                Text(verbatim: placeholder)
                    .font(.system(size: 13))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(3)
                    .accessibilityIdentifier("AdaEditor.Agent.PromptHint")
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func sourceInteraction(in geometry: GeometryProxy?) -> TextEditorSourceInteraction? {
        guard let viewModel else {
            return nil
        }
        return TextEditorSourceInteraction(
            focusedRange: viewModel.promptCompletionFocus,
            onCaretViewportRectChange: { position, caret in
                if let geometry, let onCaret {
                    let origin = geometry.frame(in: .global).origin
                    onCaret(Rect(x: origin.x + caret.minX, y: origin.y + caret.minY, width: caret.width, height: caret.height))
                }
                // Pointer moves report viewport changes without requesting completion.
                // Ignore repeated layout reports at the same source position.
                let text = viewModel.prompt
                let prefix = text.prefix(viewModel.promptCaretOffset ?? text.count)
                let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
                let previous = TextEditorSourcePosition(line: lines.count - 1, column: lines.last?.count ?? 0)
                guard position != previous else {
                    return
                }
                viewModel.updatePromptCaret(position, text: text)
            },
            onCaretChange: viewModel.updatePromptCaret,
            onRequestCompletion: { _, _ in
                viewModel.dismissCompletions()
                viewModel.dismissPromptSuggestions()
            },
            onMoveCompletionSelection: viewModel.moveCompletionSelection,
            onAcceptCompletion: { viewModel.submitPromptFromKeyboard(attachingFile: onCaret != nil) }
        )
    }

    private var composerTextEditorColors: TextEditorColors {
        TextEditorColors(
            background: onCaret == nil ? theme.editorColors.surface : .clear,
            border: Color.clear,
            focusedBorder: Color.clear,
            gutter: Color.clear,
            gutterRule: Color.clear,
            currentLineBackground: Color.clear,
            selection: theme.editorColors.blue.opacity(0.24)
        )
    }
}
