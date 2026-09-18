@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorTextSearchDialog: View {
    static let fieldIdentifier = "AdaEditor.TextSearch.Query"
    let viewModel: EditorViewModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var model: EditorTextSearchModel { viewModel.textSearch }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { close() }
                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchField
                    results
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    preview
                    footer
                }
                .frame(width: max(0, min(1040, geometry.size.width - 40)), height: max(0, min(620, geometry.size.height - 40)))
                .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.surfaceElevated))
                .overlay { RoundedRectangleShape(cornerRadius: 12).stroke(theme.editorColors.border, lineWidth: 1) }
                .accessibilityIdentifier("AdaEditor.TextSearch.Dialog")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .keyboardShortcuts([
            KeyboardShortcutAction(.escape) { close() },
            KeyboardShortcutAction(.arrowDown) { model.moveSelection(by: 1) },
            KeyboardShortcutAction(.arrowUp) { model.moveSelection(by: -1) },
        ])
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                _ = EditorSearchShortcutMonitor.shared.focusSearchField(identifier: Self.fieldIdentifier)
            }
        }
        .onDisappear { model.close() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Find in Files").font(.system(size: 18, weight: .semibold))
            Text(model.status)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
                .accessibilityIdentifier("AdaEditor.TextSearch.Status")
            Spacer()
            Button {
                close()
            } label: {
                Text("\u{E5CD}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 18))
                    .foregroundColor(theme.editorColors.muted)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.background))
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.TextSearch.Close")
        }
        .foregroundColor(theme.editorColors.text)
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            TextField(
                "Search text in project",
                text: Binding(
                    get: { model.query },
                    set: {
                        model.query = $0
                        viewModel.refreshTextSearch()
                    }
                ),
                onSubmit: { openSelected() }
            )
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 15))
            .foregroundColor(theme.editorColors.text)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(Self.fieldIdentifier)
            Button("Aa") {
                model.caseSensitive.toggle()
                viewModel.refreshTextSearch()
            }
            .foregroundColor(model.caseSensitive ? theme.editorColors.blue : theme.editorColors.muted)
            .accessibilityIdentifier("AdaEditor.TextSearch.CaseSensitive")
            Button("Whole word") {
                model.wholeWord.toggle()
                viewModel.refreshTextSearch()
            }
            .foregroundColor(model.wholeWord ? theme.editorColors.blue : theme.editorColors.muted)
            .accessibilityIdentifier("AdaEditor.TextSearch.WholeWord")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.background))
        .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border, lineWidth: 1) }
        .accessibilityIdentifier("AdaEditor.TextSearch.Field")
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var results: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.results.matches) { match in
                            resultRow(match, width: max(0, geometry.size.width - 24))
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }

    private func resultRow(_ match: EditorTextSearchMatch, width: Float) -> some View {
        Button {
            model.selectedID = match.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(match.relativePath):\(match.range.start.line + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
                    .frame(width: max(0, width - 20), alignment: .leading)
                    .accessibilityIdentifier("AdaEditor.TextSearch.Path.\(match.id)")
                Text(highlightedText(match, size: 12))
                    .lineLimit(1)
                    .frame(width: max(0, width - 20), alignment: .leading)
                    .accessibilityIdentifier("AdaEditor.TextSearch.Code.\(match.id)")
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 52, alignment: .leading)
            .background(
                RoundedRectangleShape(cornerRadius: 6)
                    .fill(
                        model.selectedID == match.id ? theme.editorColors.blue.opacity(0.20) : Color.clear
                    )
            )
            .mask(RoundedRectangleShape(cornerRadius: 6))
        }
        .buttonStyle(DefaultButtonStyle())
        .id(match.id)
        .accessibilityIdentifier("AdaEditor.TextSearch.Result.\(match.id)")
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let match = model.selectedMatch {
                Text("\(match.relativePath) · line \(match.range.start.line + 1)")
                    .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                ScrollView(.horizontal) {
                    Text(highlightedText(match, size: 13)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                .frame(height: 42)
            } else {
                Text(model.status).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 94)
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.TextSearch.Preview")
    }

    private func highlightedText(_ match: EditorTextSearchMatch, size: Double) -> AttributedText {
        EditorTextSearchPresentationText.attributedText(
            match,
            palette: viewModel.workbench.codeColorPalette,
            font: AdaEditorCodeFont.font(family: viewModel.workbench.codeFontFamily, weight: viewModel.workbench.codeFontWeight, size: size),
            keywordFont: AdaEditorCodeFont.font(family: viewModel.workbench.codeFontFamily, weight: viewModel.workbench.keywordFontWeight, size: size)
        )
    }

    private var footer: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    shortcut("Up/Down", label: "Select")
                    shortcut("Enter", label: "Open")
                    shortcut("Esc", label: "Close")
                }
                .accessibilityIdentifier("AdaEditor.TextSearch.Shortcuts")
                if model.results.skippedFiles > 0 {
                    Text("\(model.results.skippedFiles) files skipped · binary, too large or unreadable")
                        .font(.system(size: 10))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(2)
                        .accessibilityIdentifier("AdaEditor.TextSearch.Skipped")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                openSelected()
            } label: {
                Text("Open in Editor")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.blue))
            }
            .buttonStyle(DefaultButtonStyle())
            .disabled(model.selectedMatch == nil)
            .accessibilityIdentifier("AdaEditor.TextSearch.Open")
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
    }

    private func shortcut(_ key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(height: 20)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.background))
            Text(label).font(.system(size: 10))
        }
        .foregroundColor(theme.editorColors.muted)
    }

    private func close() {
        model.close()
        dismiss()
    }

    private func openSelected() {
        guard let match = model.selectedMatch else {
            return
        }
        viewModel.openTextSearchMatch(match)
        dismiss()
    }
}

struct EditorTextSearchPresentation: ViewModifier {
    let viewModel: EditorViewModel

    func body(content: Content) -> some View {
        content
            .fullScreenCover(
                isPresented: Binding(
                    get: { viewModel.textSearch.isPresented },
                    set: {
                        if !$0 {
                            viewModel.textSearch.close()
                        }
                    }
                )
            ) {
                EditorTextSearchDialog(viewModel: viewModel)
            }
            .keyboardShortcuts([
                KeyboardShortcutAction(.f, modifiers: [.command, .shift]) {
                    viewModel.presentTextSearch()
                }
            ])
    }
}
