@_spi(AdaEngine) import AdaEngine

struct EditorModifierPickerRequest: Hashable {
    let model: EditorUISceneModel
    let nodeID: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.nodeID == rhs.nodeID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(model))
        hasher.combine(nodeID)
    }
}

struct EditorAddModifierDialog: View {
    let model: EditorUISceneModel
    let nodeID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var search = ""
    @State private var hoveredID: String?

    private var entries: [EditorModifierCatalogEntry] {
        model.catalog.modifierSignatures.map { EditorModifierCatalogEntry(signature: $0) }.filter { $0.matches(search) }
    }

    private var targetName: String {
        var name = "selected layer"
        model.document.root.visit {
            if $0.id == nodeID {
                name = $0.type
            }
        }
        return name
    }

    var body: some View {
        GeometryReader { geometry in
            let width = min(680, max(0, geometry.size.width - 32))
            let height = min(680, max(0, geometry.size.height - 32))
            ZStack(anchor: .center) {
                Color.black.opacity(0.62)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { dismiss() }
                    .accessibilityIdentifier("AdaEditor.AddModifier.Backdrop")
                VStack(alignment: .leading, spacing: 0) {
                    header
                    searchField.padding(.horizontal, 20)
                        .padding(.bottom, 14)
                    modifierList.frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer
                }
                .frame(width: width, height: height)
                .background(RoundedRectangleShape(cornerRadius: 14).fill(theme.editorColors.surfaceElevated))
                .overlay { RoundedRectangleShape(cornerRadius: 14).stroke(theme.editorColors.border, lineWidth: 1) }
                .accessibilityIdentifier("AdaEditor.AddModifier.Dialog")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .keyboardShortcuts([KeyboardShortcutAction(.escape) { dismiss() }])
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            symbol("\u{E429}", size: 24)
                .foregroundColor(theme.editorColors.blue)
                .frame(width: 36, height: 36)
                .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.blue.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Modifier")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                Text("Choose a modifier to add to \(targetName).")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                symbol("\u{E5CD}", size: 20)
                    .foregroundColor(theme.editorColors.muted)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.background))
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.AddModifier.Close")
        }
        .padding(20)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            symbol("\u{E8B6}", size: 18)
                .foregroundColor(theme.editorColors.muted)
            TextField("Search by name, category, or description", text: $search)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
                .textFieldStyle(PlainTextFieldStyle())
                .accessibilityIdentifier("AdaEditor.AddModifier.Search")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    symbol("\u{E5CD}", size: 16)
                        .foregroundColor(theme.editorColors.muted)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.AddModifier.ClearSearch")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.background))
        .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border, lineWidth: 1) }
    }

    @ViewBuilder
    private var modifierList: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No modifiers found")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                Text("Try another name, category, or description.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("AdaEditor.AddModifier.EmptyState")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in modifierRow(entry) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
    }

    private func modifierRow(_ entry: EditorModifierCatalogEntry) -> some View {
        Button {
            model.addModifier(entry.id, to: nodeID)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                symbol("\u{E429}", size: 19)
                    .foregroundColor(theme.editorColors.blue)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.blue.opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entry.signature.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(theme.editorColors.text)
                        Text(entry.category)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.editorColors.blue)
                    }
                    Text(entry.description)
                        .font(.system(size: 10))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(2)
                }
                Spacer()
                Text("+")
                    .font(.system(size: 18))
                    .foregroundColor(theme.editorColors.blue)
                    .frame(width: 30, height: 30)
                    .background(CircleShape().fill(theme.editorColors.blue.opacity(0.12)))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 8).fill(hoveredID == entry.id ? theme.editorColors.blue.opacity(0.12) : theme.editorColors.surface))
            .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border.opacity(0.75), lineWidth: 1) }
        }
        .buttonStyle(DefaultButtonStyle())
        .disabled(model.isReadOnly)
        .onHover { hoveredID = $0 ? entry.id : nil }
        .accessibilityIdentifier("AdaEditor.UIScene.Modifier.Add.\(entry.id)")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(entries.count) available")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, bordered: true))
                .accessibilityIdentifier("AdaEditor.AddModifier.Cancel")
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(theme.editorColors.surface)
    }

    private func symbol(_ code: String, size: Float) -> some View {
        Text(code)
            .font(AdaEditorMaterialSymbolFont.font(size: Double(size)))
    }
}
