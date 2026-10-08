@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorScriptFieldOption: Identifiable, Equatable {
    let script: String
    let scriptName: String
    let field: String
    let type: UIValueType
    var id: String { "\(script):\(field)" }
    var label: String { "\(scriptName).\(field)" }
    var binding: UIScriptFieldBinding { .init(script: script, field: field) }
    func accepts(_ type: UIValueType) -> Bool { type == .any || type == self.type }

    static func valueType(for kind: EditorComponentFieldKind) -> UIValueType? {
        switch kind {
        case .string: .string
        case .bool: .bool
        case .float,
            .int:
            .number
        default: nil
        }
    }

    static func encode(_ mappings: [String: UIScriptFieldBinding]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(mappings)).flatMap { String(bytes: $0, encoding: .utf8) }
    }
}

struct EditorScriptFieldPicker: View {
    let options: [EditorScriptFieldOption]
    let selection: UIScriptFieldBinding?
    let onSelect: (UIScriptFieldBinding?) -> Void
    @State private var expanded = false
    @State private var search = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("\u{E157}").font(AdaEditorMaterialSymbolFont.font(size: 15))
                    Text(selectionLabel).lineLimit(1).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Text("\u{E5CF}").font(AdaEditorMaterialSymbolFont.font(size: 14))
                }
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
                .padding(8)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.ScriptFieldPicker.Toggle")
            if expanded {
                TextField("Find script or field…", text: $search)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Not bound") {
                            onSelect(nil)
                            expanded = false
                        }
                        .accessibilityIdentifier("AdaEditor.ScriptFieldPicker.Unlink")
                        ForEach(options.filter { search.isEmpty || "\($0.script) \($0.label)".localizedCaseInsensitiveContains(search) }) { option in
                            Button {
                                onSelect(option.binding)
                                expanded = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.system(size: 12))
                                    Text("\(option.script) · \(option.type.rawValue)").font(.system(size: 10))
                                        .foregroundColor(theme.editorColors.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(DefaultButtonStyle())
                            .accessibilityIdentifier("AdaEditor.ScriptFieldPicker.Option.\(option.id)")
                        }
                        if options.isEmpty {
                            Text("No compatible exported fields.").font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                        }
                    }
                }
                .frame(height: min(180, Float(options.count + 1) * 44))
            }
        }
    }

    private var selectionLabel: String {
        guard let selection else {
            return "Not bound"
        }
        return options.first { $0.binding == selection }?.label ?? "\(selection.script).\(selection.field)"
    }
}

struct EditorScriptBindingsView: View {
    let model: EditorInspectorSidebarViewModel
    let typeName: String
    @State private var showsJSON = false
    @Environment(\.theme) private var theme

    var body: some View {
        let inputs = model.uiBindingInputs(for: typeName)
        let mappings = model.uiScriptBindings(for: typeName)
        let failure = model.uiBindingsError(for: typeName) ?? model.uiBindingSourceIssue(for: typeName)
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect UI inputs to exported fields on this entity.")
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundColor(.red)
            }
            ForEach(inputs, id: \.name) { input in
                bindingRow(input.name, type: input.type, mapping: mappings[input.name])
                    .disabled(failure != nil)
            }
            ForEach(mappings.keys.filter { name in !inputs.contains { $0.name == name } }.sorted(), id: \.self) { name in
                bindingRow(name, type: .any, mapping: mappings[name])
                    .disabled(failure != nil)
            }
            if inputs.isEmpty {
                Text("Choose a .ui source with declared inputs. Add inputs in the UI Designer.")
                    .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            } else {
                Button("Match by name") { model.matchUIBindingsByName(typeName: typeName) }
                    .disabled(failure != nil)
                    .accessibilityIdentifier("AdaEditor.UIBinding.Add")
            }
            Button(showsJSON ? "Hide JSON" : "Show JSON") { showsJSON.toggle() }
                .accessibilityIdentifier("AdaEditor.UIBinding.JSON.Toggle")
            if showsJSON, let field = model.uiFields(for: typeName).first(where: { $0.field.key == "scriptBindings" }) {
                TextField("Bindings JSON", text: model.componentFieldBinding(typeName: typeName, field: field.field))
                    .accessibilityIdentifier("AdaEditor.UIBinding.JSON")
            }
        }
        .id("\(model.selectedEntity?.editorID ?? ""): \(typeName)")
    }

    private func bindingRow(_ name: String, type: UIValueType, mapping: UIScriptFieldBinding?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(type.rawValue).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            }
            EditorScriptFieldPicker(options: model.uiScriptFieldOptions.filter { $0.accepts(type) }, selection: mapping) {
                model.setUIBinding(name, to: $0, typeName: typeName)
            }
            if let mapping, let issue = model.uiBindingIssue(input: name, mapping: mapping, typeName: typeName) {
                Text(issue).font(.system(size: 11)).foregroundColor(.red)
            }
        }
        .accessibilityIdentifier("AdaEditor.UIBinding.\(name)")
    }
}
