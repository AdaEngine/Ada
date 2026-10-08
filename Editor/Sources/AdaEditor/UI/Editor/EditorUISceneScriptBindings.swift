@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorUIBindingOwner: Identifiable {
    let documentID: String
    let entityID: String
    let typeName: String
    let sourcePath: String
    let label: String
    let options: [EditorScriptFieldOption]
    let mappings: [String: UIScriptFieldBinding]
    let issue: String?
    var id: String { "\(documentID):\(entityID):\(typeName)" }
}

extension EditorWorkbenchViewModel {
    func uiBindingOwners(sourceURL: URL?, resourceRoot: URL?, catalog: [EditorScriptableObjectDescriptor]) -> [EditorUIBindingOwner] {
        guard let sourceURL else {
            return []
        }
        let resources = UISceneResources(rootURL: resourceRoot ?? sourceURL.deletingLastPathComponent())
        var result: [EditorUIBindingOwner] = []
        for case let .scene(document) in openDocuments where !document.isReadOnly {
            guard let scene = document.sceneModel ?? EditorSceneFileLoader.model(from: document.content) else {
                continue
            }
            for entity in scene.entities {
                let scripts: [String]
                if case let .array(values)? = entity.components[EditorBuiltInComponentType.scriptableComponents]?["scripts"] {
                    scripts = values.compactMap { value in
                        guard case let .object(object) = value else {
                            return nil
                        }
                        return object["type"]?.stringValue
                    }
                } else {
                    scripts = []
                }
                let options = catalog.filter { scripts.contains($0.identifier) }
                    .flatMap { script in
                        script.fields.compactMap { field -> EditorScriptFieldOption? in
                            guard let type = EditorScriptFieldOption.valueType(for: field.kind) else {
                                return nil
                            }
                            return .init(script: script.identifier, scriptName: script.name, field: field.name, type: type)
                        }
                    }
                for typeName in [EditorBuiltInComponentType.uiComponent, EditorBuiltInComponentType.companionPanel] {
                    guard
                        let payload = entity.components[typeName], let path = payload["path"]?.stringValue,
                        let resolved = try? resources.resolve(path),
                        resolved.standardizedFileURL.resolvingSymlinksInPath() == sourceURL.standardizedFileURL.resolvingSymlinksInPath()
                    else {
                        continue
                    }
                    let text = payload["scriptBindings"]?.stringValue ?? "{}"
                    let mappings = try? JSONDecoder().decode([String: UIScriptFieldBinding].self, from: Data(text.utf8))
                    let context = payload["contextName"]?.stringValue ?? ""
                    let kind = payload["kind"]?.stringValue ?? "ui"
                    let issue =
                        mappings == nil
                        ? "Fix invalid bindings JSON in the scene inspector."
                        : (!context.isEmpty
                            ? "Clear Data context in the scene inspector."
                            : (kind != "ui" ? "Script bindings require a .ui source." : nil))
                    result.append(
                        .init(
                            documentID: document.id,
                            entityID: entity.id,
                            typeName: typeName,
                            sourcePath: path,
                            label: "\(document.title) / \(entity.name) / \(typeName == EditorBuiltInComponentType.companionPanel ? "Companion Panel" : "UI Component")",
                            options: options,
                            mappings: mappings ?? [:],
                            issue: issue
                        )
                    )
                }
            }
        }
        return result
    }

    /// Changes only this owner's bindings. Conflicting edits are rejected rather than overwritten by UI undo.
    func replaceUIBindings(owner: EditorUIBindingOwner, expected: [String: UIScriptFieldBinding], replacement: [String: UIScriptFieldBinding]) -> Bool {
        guard
            let index = openDocuments.firstIndex(where: { $0.id == owner.documentID }),
            case var .scene(document) = openDocuments[index], !document.isReadOnly,
            var scene = document.sceneModel ?? EditorSceneFileLoader.model(from: document.content),
            let entityIndex = scene.entities.firstIndex(where: { $0.id == owner.entityID }),
            let payload = scene.entities[entityIndex].components[owner.typeName],
            payload["path"]?.stringValue == owner.sourcePath,
            let current = try? JSONDecoder().decode([String: UIScriptFieldBinding].self, from: Data((payload["scriptBindings"]?.stringValue ?? "{}").utf8)),
            current == expected, let text = EditorScriptFieldOption.encode(replacement)
        else {
            return false
        }
        scene.entities[entityIndex].components[owner.typeName]?["scriptBindings"] = .string(text)
        guard let content = try? scene.encodedYAML() else {
            return false
        }
        document.content = content
        document.sceneModel = scene
        document.isDirty = content != document.lastSavedContent
        document.statusMessage = "UI binding edited"
        document.loadSummary = EditorSceneFileLoader.summary(from: content)
        // This edit belongs to the UI Designer's compound undo step, not a second scene undo step.
        openDocuments[index] = .scene(document)
        notifyActiveDocumentChangedIfNeeded(documentID: document.id)
        onDocumentEdited?(document.id)
        return true
    }
}

extension EditorUISceneModel {
    var bindingOwners: [EditorUIBindingOwner] { onBindingOwners?() ?? [] }
    var bindingOwner: EditorUIBindingOwner? {
        let owners = bindingOwners
        if let selectedBindingOwnerID {
            return owners.first { $0.id == selectedBindingOwnerID }
        }
        return owners.count == 1 ? owners.first : nil
    }

    func bindParameter(_ parameter: UIParameter, nodeID: String, modifierID: String?, to mapping: UIScriptFieldBinding) {
        guard
            let owner = bindingOwner, owner.issue == nil,
            let option = owner.options.first(where: { $0.binding == mapping && $0.accepts(parameter.type) }),
            let change = onBindingChange
        else {
            error = "Choose a scene owner and a compatible exported field."
            return
        }
        var target: UINodeDescription?
        document.root.visit {
            if $0.id == nodeID {
                target = $0
            }
        }
        guard let target, modifierID == nil || target.modifiers.contains(where: { $0.id == modifierID }) else {
            error = "The selected UI property is no longer available."
            return
        }
        let currentArgument =
            modifierID.flatMap { id in target.modifiers.first { $0.id == id }?.arguments[parameter.name] }
            ?? target.arguments[parameter.name]
        let initialValue = currentArgument?.value ?? parameter.defaultValue ?? EditorUISceneEditor.defaultValue(option.type)
        var inputName = option.field
        // Reuse only an input already connected to this field; otherwise preserve all existing input uses.
        if let existing = document.inputs.first(where: { owner.mappings[$0.name] == mapping && (parameter.type == .any || $0.type == parameter.type) }) {
            inputName = existing.name
        } else {
            var suffix = 2
            while document.inputs.contains(where: { $0.name == inputName }) || owner.mappings[inputName] != nil {
                inputName = "\(option.field)\(suffix)"
                suffix += 1
            }
        }
        var after = owner.mappings
        after[inputName] = mapping
        let name = inputName
        edit(
            { document in
                if !document.inputs.contains(where: { $0.name == name }) {
                    document.inputs.append(.init(name, type: option.type, defaultValue: initialValue))
                }
                Self.modify(&document.root, id: nodeID) { node in
                    if let modifierID, let index = node.modifiers.firstIndex(where: { $0.id == modifierID }) {
                        node.modifiers[index].arguments[parameter.name] = .init(binding: name)
                    } else if modifierID == nil {
                        node.arguments[parameter.name] = .init(binding: name)
                    }
                }
            },
            externalChange: { forward in
                change(owner, forward ? owner.mappings : after, forward ? after : owner.mappings)
            }
        )
    }
}

extension EditorUISceneEditor {
    func scriptBindingPicker(_ parameter: UIParameter, argument: UIArgument?, modifierID: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let owners = model.bindingOwners
            if owners.isEmpty {
                Text("Open a scene that uses this UI and attach a script with @export fields.")
                    .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            } else {
                Text("Scene owner").font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                ForEach(owners) { owner in
                    Button {
                        model.selectedBindingOwnerID = owner.id
                    } label: {
                        Text(owner.label).font(.system(size: 11)).lineLimit(2)
                            .foregroundColor(model.bindingOwner?.id == owner.id ? theme.editorColors.blue : theme.editorColors.text)
                    }
                    .accessibilityIdentifier("AdaEditor.UIScene.BindingOwner.\(owner.id)")
                }
                if let owner = model.bindingOwner {
                    if let issue = owner.issue {
                        Text(issue).font(.system(size: 11)).foregroundColor(.red)
                    } else {
                        EditorScriptFieldPicker(
                            options: owner.options.filter { $0.accepts(parameter.type) },
                            selection: argument?.binding.flatMap { owner.mappings[$0] }
                        ) { mapping in
                            if let mapping {
                                model.bindParameter(parameter, nodeID: model.selectedID, modifierID: modifierID, to: mapping)
                            } else {
                                model.updateSelected { node in
                                    let value = UIArgument(value: parameter.defaultValue ?? Self.defaultValue(parameter.type))
                                    if let modifierID, let index = node.modifiers.firstIndex(where: { $0.id == modifierID }) {
                                        node.modifiers[index].arguments[parameter.name] = value
                                    } else if modifierID == nil {
                                        node.arguments[parameter.name] = value
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("Select the entity to change. Other instances keep their bindings.")
                        .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                }
            }
        }
    }
}
