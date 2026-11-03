@_spi(AdaEngine) import AdaEngine

/// Suggestions only fill the draft; sending remains an explicit composer action.
struct EditorAgentSuggestionsView: View {
    let viewModel: EditorAgentViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        if let purpose = viewModel.promptSuggestions.purpose,
           !viewModel.promptSuggestions.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(purpose == .completion ? L10n.text("Continue your message") : L10n.text("What next?"))
                        .font(.system(size: 10))
                        .foregroundColor(theme.editorColors.muted)
                    Spacer()
                    Button(L10n.text("Dismiss suggestions"), action: viewModel.dismissPromptSuggestions)
                        .font(.system(size: 10))
                        .foregroundColor(theme.editorColors.muted)
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Agent.DismissPromptSuggestions")
                }
                ForEach(Array(viewModel.promptSuggestions.suggestions.prefix(purpose == .completion ? 1 : 3).enumerated()), id: \.offset) { index, suggestion in
                    Button(action: { viewModel.insertPromptSuggestion(suggestion) }) {
                        Text(verbatim: purpose == .completion ? String(suggestion.dropFirst(viewModel.prompt.count)) : suggestion)
                            .font(.system(size: 12))
                            .foregroundColor(theme.editorColors.text)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(EditorPickerRowButtonStyle(theme: theme, selectionColor: theme.editorColors.blue.opacity(0.07), cornerRadius: 7))
                    .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestion.\(index)")
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
            .accessibilityIdentifier("AdaEditor.Agent.PromptSuggestions")
        }
    }
}
