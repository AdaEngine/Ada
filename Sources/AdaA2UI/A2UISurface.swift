import AdaUI
import AdaUIDescription
import Foundation

/// UI state is scoped to a surface; external side effects remain the host's responsibility.
@MainActor
public final class A2UISurface {
    public let id: String
    public let generation = UUID()
    public let scene: UISceneInstance
    public private(set) var dataModel: UIValue = .object([:])
    let sendDataModel: Bool
    var components: [String: A2UIComponent] = [:]
    var emit: (@MainActor (A2UIClientEvent) -> Void)?
    var didChange: (@MainActor () -> Void)?
    private var isActive = true
    private var mountedActions = Set<String>()
    private var bindingValues: [String: A2UIDynamicValue] = [:]

    init(id: String, sendDataModel: Bool) throws {
        self.id = id
        self.sendDataModel = sendDataModel
        scene = try UISceneInstance(document: .init(root: .init(id: "root", type: "EmptyView")))
    }

    /// Converts the supported surface into an editable `.ui` document for Ada Studio.
    /// Data paths become named inputs with current defaults. Actions become host-owned event names.
    public func snapshot() throws -> UISceneDocument {
        var document = scene.document
        document.inputs = try bindingValues.sorted { $0.key < $1.key }.map { key, value in
            UIParameter(key, type: value.type, defaultValue: try value.resolved(in: dataModel), isBinding: true)
        }
        var actions = Set<String>()
        let sourceComponents = Dictionary(uniqueKeysWithValues: components.map { (sceneNodeID($0.key), $0.value) })
        func export(_ node: inout UINodeDescription) throws {
            if let component = sourceComponents[node.id], component.type == "Button" {
                let action = try A2UIAction(component.properties["action"])
                node.actions["action"] = action.name
                actions.insert(action.name)
            }
            for index in node.children.indices { try export(&node.children[index]) }
        }
        try export(&document.root)
        document.actions = actions.sorted().map { UIActionSignature($0) }
        try document.validate()
        return document
    }

    func deactivate() {
        isActive = false
        emit = nil
        didChange = nil
    }

    func update(components candidate: [String: A2UIComponent]? = nil, dataModel model: UIValue? = nil) throws {
        let proposed = candidate ?? components
        let proposedModel = model ?? dataModel
        // Validate even unreachable components so invalid buffered definitions cannot be committed.
        try validateGraph(proposed)
        var bindings: [String: A2UIDynamicValue] = [:]
        var actions: [String: String] = [:]
        var visited = Set<String>()
        let root = try makeNode("root", components: proposed, model: proposedModel, visited: &visited, bindings: &bindings, actions: &actions)
        let document = UISceneDocument(root: root)
        try document.validate()
        let previousModel = dataModel
        dataModel = proposedModel
        for (name, value) in bindings {
            let pointer = value.pointer
            scene.context.bind(name, to: Binding(
                get: { [weak self] in pointer?.read(self?.dataModel ?? .null) ?? value.fallback },
                set: { [weak self] newValue in
                    guard let self, self.isActive, let pointer, value.type.accepts(newValue) else {
                        return
                    }
                    do { try self.update(dataModel: pointer.replacing(in: self.dataModel, with: newValue)) } catch { self.report(error) }
                }
            ))
        }
        for componentID in actions.keys {
            scene.context.on(actionToken(componentID)) { [weak self] _ in self?.dispatch(componentID) }
        }
        if candidate != nil {
            guard scene.update(document) else {
                dataModel = previousModel
                throw A2UIValidationError(message: scene.diagnostic ?? "Unable to render candidate surface.")
            }
            components = proposed
            bindingValues = bindings
            mountedActions = Set(actions.keys)
        } else {
            scene.context.invalidate()
        }
        didChange?()
    }

    /// Compact protocol messages for restoring this surface, including locally edited data.
    /// Restore them in order into a new client; callbacks and transport ownership are not serialized.
    public func restorationMessages() -> [UIValue] {
        [
            .object([
                "version": .string("v0.9.1"),
                "createSurface": .object([
                    "surfaceId": .string(id), "catalogId": .string(A2UIClient.catalogID), "sendDataModel": .bool(sendDataModel)
                ])
            ]),
            .object([
                "version": .string("v0.9.1"),
                "updateComponents": .object([
                    "surfaceId": .string(id),
                    "components": .array(components.keys.sorted().compactMap { components[$0].map { .object($0.properties) } })
                ])
            ]),
            .object([
                "version": .string("v0.9.1"),
                "updateDataModel": .object(["surfaceId": .string(id), "value": dataModel])
            ])
        ]
    }

    private func validateGraph(_ components: [String: A2UIComponent]) throws {
        var active = Set<String>()
        var completed = Set<String>()
        func visit(_ id: String, depth: Int) throws {
            guard !active.contains(id), depth <= 64 else {
                throw A2UIValidationError(path: "/components", message: "Cyclic or excessively nested component graph.")
            }
            guard !completed.contains(id), let component = components[id] else {
                return
            }
            active.insert(id)
            for child in component.children { try visit(child, depth: depth + 1) }
            active.remove(id)
            completed.insert(id)
        }
        for id in components.keys.sorted() { try visit(id, depth: 0) }
    }

    private func makeNode(
        _ componentID: String,
        components: [String: A2UIComponent],
        model: UIValue,
        visited: inout Set<String>,
        bindings: inout [String: A2UIDynamicValue],
        actions: inout [String: String]
    ) throws -> UINodeDescription {
        guard visited.insert(componentID).inserted else {
            throw A2UIValidationError(path: "/components", message: "A component cannot be mounted under multiple parents.")
        }
        guard let component = components[componentID] else {
            return .init(id: sceneNodeID(componentID), type: "EmptyView")
        }
        var node = UINodeDescription(id: sceneNodeID(component.id), type: component.type)
        node.modifiers = [.init(id: "identity", type: "accessibilityIdentifier", arguments: ["value": .init(value: .string("a2ui.\(id).\(component.id)"))])]
        func argument(_ property: String, type: UIValueType, writable: Bool = false) throws -> UIArgument {
            let value = try A2UIDynamicValue(component.properties[property], type: type, requiresBinding: writable)
            _ = try value.resolved(in: model)
            if let pointer = value.pointer {
                if let previous = bindings[pointer.bindingName], previous.type != .any, previous.type != type {
                    throw A2UIValidationError(path: pointer.path, message: "One data path cannot bind incompatible property types.")
                }
                bindings[pointer.bindingName] = value
                return .init(binding: pointer.bindingName)
            }
            return .init(value: value.literal ?? value.fallback)
        }
        switch component.type {
        case "Row", "Column":
            node.type = component.type == "Row" ? "HStack" : "VStack"
            node.arguments["spacing"] = .init(value: component.properties["spacing"] ?? .number(12))
            if component.type == "Column" { node.arguments["alignment"] = .init(value: .string("leading")) }
            for child in component.children {
                node.children.append(try makeNode(child, components: components, model: model, visited: &visited, bindings: &bindings, actions: &actions))
            }
        case "Text": node.arguments["text"] = try argument("text", type: .string)
        case "TextField":
            node.arguments["text"] = try argument("text", type: .string, writable: true)
            node.arguments["placeholder"] = .init(value: component.properties["placeholder"] ?? .string(""))
            node.modifiers.append(.init(id: "inputSize", type: "frame", arguments: ["height": .init(value: .number(36))]))
        case "Toggle":
            node.arguments["title"] = try argument("label", type: .string)
            node.arguments["isOn"] = try argument("value", type: .bool, writable: true)
        case "ChoicePicker":
            node.arguments["selection"] = try argument("value", type: .string, writable: true)
            node.arguments["label"] = component.properties["label"] == nil ? .init(value: .string("")) : try argument("label", type: .string)
            node.arguments["options"] = .init(value: component.properties["options"] ?? .array([]))
            node.arguments["identifier"] = .init(value: .string("a2ui.\(id).\(component.id)"))
        case "Slider":
            node.arguments["value"] = try argument("value", type: .number, writable: true)
            for name in ["min", "max", "step"] {
                node.arguments[name] = .init(value: component.properties[name] ?? .number(0))
            }
        case "Button":
            node.arguments["title"] = try argument("text", type: .string)
            let action = try A2UIAction(component.properties["action"])
            actions[component.id] = action.name
            node.actions["action"] = actionToken(component.id)
        default: break
        }
        let checks = try A2UIFormChecks(component.properties["checks"])
        if !checks.checks.isEmpty {
            let compiled = try checks.compiled(bindings: &bindings)
            node.modifiers.append(.init(id: "validation", type: "formValidation", arguments: [
                "checks": .init(value: compiled), "disablesContent": .init(value: .bool(component.type == "Button"))
            ]))
        }
        return node
    }

    private func sceneNodeID(_ componentID: String) -> String {
        componentID.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }

    private func actionToken(_ componentID: String) -> String { "event:" + componentID }

    private func dispatch(_ componentID: String) {
        guard isActive, mountedActions.contains(componentID), let component = components[componentID], component.type == "Button" else {
            return
        }
        do {
            // Recheck at dispatch time too: retained callbacks must not bypass invalid form state.
            guard try A2UIFormChecks(component.properties["checks"]).accepts(dataModel) else {
                return
            }
            let action = try A2UIAction(component.properties["action"])
            let envelope: UIValue = .object([
                "action": .object([
                    "name": .string(action.name),
                    "surfaceId": .string(id),
                    "sourceComponentId": .string(componentID),
                    "timestamp": .string(Date().ISO8601Format()),
                    "context": try action.resolve(in: dataModel)
                ])
            ])
            let metadata: UIValue = sendDataModel
                ? .object(["a2uiClientDataModel": .object(["surfaces": .object([id: dataModel])])])
                : .object([:])
            emit?(.init(envelope: envelope, metadata: metadata))
        } catch { report(error) }
    }

    private func report(_ error: any Error) {
        let failure = A2UIValidationError(surfaceID: id, message: error.localizedDescription)
        emit?(.init(envelope: failure.envelope))
    }
}
