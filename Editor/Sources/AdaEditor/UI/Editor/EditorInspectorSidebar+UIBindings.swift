@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorInspectorSidebar {
    func scriptUIBindingsEditor(_ field: EditorInspectorSidebarViewModel.ComponentField) -> some View {
        EditorScriptBindingsView(model: viewModel, typeName: field.typeName)
    }
}

extension EditorInspectorSidebarViewModel {
    func uiFields(for typeName: String) -> [ComponentField] {
        selectedEntity?.components.first { $0.typeName == typeName }?.fields ?? []
    }

    func uiBindingsText(for typeName: String) -> String {
        uiFields(for: typeName).first { $0.field.key == "scriptBindings" }?.value ?? "{}"
    }

    func uiBindingsError(for typeName: String) -> String? {
        do {
            _ = try JSONDecoder().decode([String: UIScriptFieldBinding].self, from: Data(uiBindingsText(for: typeName).utf8))
            return nil
        } catch {
            return "Invalid bindings JSON. Fix it in JSON before editing connections."
        }
    }

    func uiBindingSourceIssue(for typeName: String) -> String? {
        let fields = uiFields(for: typeName)
        if let context = fields.first(where: { $0.field.key == "contextName" })?.value, !context.isEmpty {
            return "Clear Data context to connect fields on this entity."
        }
        if let kind = fields.first(where: { $0.field.key == "kind" })?.value, !kind.isEmpty, kind != "ui" {
            return "Choose a .ui source to connect script fields."
        }
        return nil
    }

    func uiScriptBindings(for typeName: String) -> [String: UIScriptFieldBinding] {
        (try? JSONDecoder().decode([String: UIScriptFieldBinding].self, from: Data(uiBindingsText(for: typeName).utf8))) ?? [:]
    }

    var uiScriptBindings: [String: UIScriptFieldBinding] { uiScriptBindings(for: EditorBuiltInComponentType.uiComponent) }
    var uiBindingInputs: [UIParameter] { uiBindingInputs(for: EditorBuiltInComponentType.uiComponent) }
    var uiBindingInputNames: [String] { uiBindingInputs.map(\.name) }

    func uiBindingInputs(for typeName: String) -> [UIParameter] {
        guard
            let path = uiFields(for: typeName).first(where: { $0.field.key == "path" })?.value,
            let file = uiSceneFiles[path],
            let source = uiSourceContent?(file) ?? (try? String(contentsOfFile: file, encoding: .utf8)),
            let document = try? UISceneDocument.decode(source)
        else {
            return []
        }
        return document.inputs
    }

    var uiScriptFieldOptions: [EditorScriptFieldOption] {
        (selectedEntity?.scriptableObjects ?? [])
            .flatMap { script in
                script.fields.compactMap { field in
                    guard let type = EditorScriptFieldOption.valueType(for: field.field.kind) else {
                        return nil
                    }
                    return EditorScriptFieldOption(script: script.identifier, scriptName: script.displayName, field: field.field.key, type: type)
                }
            }
    }

    func setUIBinding(_ input: String, to mapping: UIScriptFieldBinding?, typeName: String = EditorBuiltInComponentType.uiComponent) {
        guard uiBindingsError(for: typeName) == nil else {
            return
        }
        var mappings = uiScriptBindings(for: typeName)
        mappings[input] = mapping
        saveUIBindings(mappings, typeName: typeName)
    }

    func renameUIBinding(_ input: String, to name: String) {
        guard input != name, uiBindingInputNames.contains(name) else {
            return
        }
        var mappings = uiScriptBindings
        guard mappings[name] == nil, let mapping = mappings.removeValue(forKey: input) else {
            return
        }
        mappings[name] = mapping
        saveUIBindings(mappings, typeName: EditorBuiltInComponentType.uiComponent)
    }

    func matchUIBindingsByName(typeName: String) {
        guard uiBindingsError(for: typeName) == nil, uiBindingSourceIssue(for: typeName) == nil else {
            return
        }
        var mappings = uiScriptBindings(for: typeName)
        for input in uiBindingInputs(for: typeName) where mappings[input.name] == nil {
            let candidates = uiScriptFieldOptions.filter { $0.field == input.name && $0.accepts(input.type) }
            if candidates.count == 1 {
                mappings[input.name] = candidates.first?.binding
            }
        }
        saveUIBindings(mappings, typeName: typeName)
    }

    func uiBindingIssue(input: String, mapping: UIScriptFieldBinding, typeName: String = EditorBuiltInComponentType.uiComponent) -> String? {
        if let name = uiFields(for: typeName).first(where: { $0.field.key == "contextName" })?.value, !name.isEmpty {
            return "Clear Data context to use this entity's script fields."
        }
        guard let parameter = uiBindingInputs(for: typeName).first(where: { $0.name == input }) else {
            return "UI input '\(input)' is missing. Declare it in the UI Designer."
        }
        guard let field = uiScriptFieldOptions.first(where: { $0.binding == mapping }) else {
            return "Script or exported field is missing or unsupported. Select another field or unlink it."
        }
        return field.accepts(parameter.type) ? nil : "Input is \(parameter.type.rawValue); field is \(field.type.rawValue)."
    }

    private func saveUIBindings(_ mappings: [String: UIScriptFieldBinding], typeName: String) {
        guard
            let field = uiFields(for: typeName).first(where: { $0.field.key == "scriptBindings" }),
            let text = EditorScriptFieldOption.encode(mappings)
        else {
            return
        }
        componentFieldBinding(typeName: typeName, field: field.field).wrappedValue = text
    }
}
