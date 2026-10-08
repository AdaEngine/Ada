import AdaRender
import AdaUIDescription
import AdaUtils
import Foundation
import Observation

/// Owns one mounted UI instance. Invalid edits leave the last successfully constructed tree mounted.
@MainActor @Observable
public final class UISceneInstance {
    private var contentRevision: UInt64 = 0
    public private(set) var document: UISceneDocument
    public let context: UIBindingContext
    public let catalog: UICatalog
    public let resources: UISceneResources?
    public let sourceURL: URL?
    public private(set) var diagnostic: String?
    @ObservationIgnored private var instances: [String: UIBindingContext] = [:]
    @ObservationIgnored private var lastView = AnyView(EmptyView())
    @ObservationIgnored private var usedInstances = Set<String>()

    public init(
        document: UISceneDocument,
        context: UIBindingContext = .init(),
        catalog: UICatalog = .standard,
        resources: UISceneResources? = nil,
        sourceURL: URL? = nil
    ) throws {
        try document.validate()
        self.document = document
        self.context = context
        self.catalog = catalog
        self.resources = resources
        self.sourceURL = sourceURL
        context.applyDefaults(document.inputs)
        try validateInputs(document, context: context)
        lastView = try makeRoot(document)
    }

    @discardableResult
    public func update(_ candidate: UISceneDocument) -> Bool {
        let previousInstances = instances
        let previousStates = instances.mapValues { $0.snapshot() }
        let previousContext = context.snapshot()
        do {
            try candidate.validate()
            try validateInputs(candidate, context: context)
            let view = try makeRoot(candidate)
            document = candidate
            lastView = view
            contentRevision &+= 1
            diagnostic = nil
            return true
        } catch {
            context.restore(previousContext)
            for (key, state) in previousStates { previousInstances[key]?.restore(state) }
            instances = previousInstances
            diagnostic = error.localizedDescription
            return false
        }
    }

    public func render() -> AnyView {
        _ = contentRevision
        do { lastView = try makeRoot(document) } catch { context.report(UIDiagnostic(error.localizedDescription)) }
        return lastView
    }

    public func resourceChanged(_ event: UISceneResourceChanged) {
        guard let resources else {
            return
        }
        let url = event.url.resolvingSymlinksInPath().standardizedFileURL
        guard sourceURL == url || resources.dependencies.contains(url) else {
            return
        }
        do {
            if let document = event.document {
                try resources.publish(document, at: url)
            } else {
                resources.invalidate(url)
            }
            let candidate = try sourceURL.map(resources.load) ?? document
            _ = update(candidate)
            context.invalidate()
        } catch { diagnostic = error.localizedDescription }
    }

    private func makeRoot(_ document: UISceneDocument) throws -> AnyView {
        usedInstances.removeAll(keepingCapacity: true)
        let view = try renderNode(document.root, context: context, scope: "root", source: sourceURL, ancestry: sourceURL.map { [$0] } ?? [])
        instances = instances.filter { usedInstances.contains($0.key) }
        return view
    }

    private func validateInputs(_ document: UISceneDocument, context: UIBindingContext) throws {
        for input in document.inputs {
            guard let value = context.value(input.name), input.type.accepts(value) else {
                throw UIDiagnostic("Missing or invalid input '\(input.name)'.")
            }
        }
        for action in document.actions where !context.hasAction(action.name) { throw UIDiagnostic("Missing action '\(action.name)'.") }
    }

    private func instance(_ key: String, parent: UIBindingContext? = nil) -> UIBindingContext {
        usedInstances.insert(key)
        if let context = instances[key] {
            return context
        }
        let context = UIBindingContext(parent: parent)
        instances[key] = context
        return context
    }

    private func renderNode(_ node: UINodeDescription, context: UIBindingContext, scope: String, source: URL?, ancestry: [URL]) throws -> AnyView {
        let identity = scope + "/" + node.id
        guard let descriptor = catalog.views[node.type], descriptor.signature.version == node.version else {
            throw UIDiagnostic("Missing or incompatible View '\(node.type)' v\(node.version).", nodeID: node.id)
        }
        var view: AnyView
        if node.type == "UI" {
            view = try renderInclude(node, context: context, identity: identity, source: source, ancestry: ancestry)
        } else {
            let inputs = try factoryContext(signature: descriptor.signature, arguments: node.arguments, actions: node.actions, context: context, children: [], nodeID: node.id)
            let children: [UIRenderedChild]
            if node.type == "If" {
                guard node.children.count <= 2 else {
                    throw UIDiagnostic("If accepts true and optional false branches.", nodeID: node.id)
                }
                let index = inputs.bool("condition") ? 0 : 1
                children = try node.children.indices.contains(index) ? [renderChild(node.children[index], context: context, scope: identity, source: source, ancestry: ancestry)] : []
            } else if node.type == "ForEach" {
                guard node.children.count == 1 else {
                    throw UIDiagnostic("ForEach requires one template.", nodeID: node.id)
                }
                var ids = Set<UIValue>()
                children = try (inputs.arguments["items"]?.array ?? [])
                    .map { item in
                        let key = inputs.string("idKey").split(separator: ".").map(String.init)
                        guard let id = item.value(at: key[...]), id.string != nil || id.number != nil, ids.insert(id).inserted else {
                            throw UIDiagnostic("ForEach requires unique string or number IDs.", nodeID: node.id)
                        }
                        let itemID = id.string.map { "s:\($0)" } ?? "n:\(id.number ?? 0)"
                        let childContext = instance(identity + "/" + itemID, parent: context)
                        if let collection = node.arguments["items"]?.binding {
                            childContext.bind(
                                "item",
                                to: Binding(
                                    get: {
                                        context.value(collection)?.array?.first { $0.value(at: key[...]) == id } ?? .null
                                    },
                                    set: { updated in
                                        guard
                                            var items = context.value(collection)?.array,
                                            let index = items.firstIndex(where: { $0.value(at: key[...]) == id })
                                        else {
                                            return
                                        }
                                        items[index] = updated
                                        context.set(collection, to: .array(items))
                                    }
                                )
                            )
                        } else {
                            childContext.set("item", to: item)
                        }
                        for (name, argument) in node.arguments where name != "items" && name != "idKey" {
                            if let binding = argument.binding {
                                childContext.bind(name, to: context.binding(binding))
                            } else if let value = argument.value {
                                childContext.set(name, to: value)
                            }
                        }
                        for (event, action) in node.actions { childContext.on(event) { context.perform(action, arguments: $0) } }
                        return UIRenderedChild(id: itemID, view: try renderNode(node.children[0], context: childContext, scope: identity + "/" + itemID, source: source, ancestry: ancestry))
                    }
            } else {
                try validateContent(descriptor.signature.content, count: node.children.count, nodeID: node.id)
                children = try node.children.map { try renderChild($0, context: context, scope: identity, source: source, ancestry: ancestry) }
            }
            var factory = UIFactoryContext(arguments: inputs.arguments, bindings: inputs.bindings, actions: inputs.actions, context: context, children: children)
            factory.resources = resources
            factory.sourceURL = source
            factory.actionSignatures = descriptor.signature.actions
            view = try descriptor.makeView(factory)
        }
        for modifier in node.modifiers {
            guard let descriptor = catalog.modifiers[modifier.type], descriptor.signature.version == modifier.version else {
                throw UIDiagnostic("Missing or incompatible modifier '\(modifier.type)'.", nodeID: node.id)
            }
            try validateContent(descriptor.signature.content, count: modifier.children.count, nodeID: node.id)
            let children = try modifier.children.map { try renderChild($0, context: context, scope: identity + "/" + modifier.id, source: source, ancestry: ancestry) }
            var factory = try factoryContext(signature: descriptor.signature, arguments: modifier.arguments, actions: modifier.actions, context: context, children: children, nodeID: node.id)
            factory.resources = resources
            factory.sourceURL = source
            factory.actionSignatures = descriptor.signature.actions
            view = try descriptor.apply(view, factory)
        }
        return AnyView(view.modifier(UISceneIdentity(content: view, nodeID: node.id)).id(identity))
    }

    private func renderChild(_ node: UINodeDescription, context: UIBindingContext, scope: String, source: URL?, ancestry: [URL]) throws -> UIRenderedChild {
        UIRenderedChild(id: node.id, view: try renderNode(node, context: context, scope: scope, source: source, ancestry: ancestry))
    }

    private func renderInclude(_ node: UINodeDescription, context: UIBindingContext, identity: String, source: URL?, ancestry: [URL]) throws -> AnyView {
        guard let resources, let path = node.arguments["path"]?.value?.string, !path.isEmpty else {
            throw UIDiagnostic("UI requires a literal resource path.", nodeID: node.id)
        }
        let url = try resources.resolve(path, relativeTo: source)
        guard !ancestry.contains(url), ancestry.count < 64 else {
            throw UIDiagnostic("Cyclic or excessively nested UI: \(path)", nodeID: node.id)
        }
        let childDocument = try resources.load(url)
        let childContext = instance(identity)
        childContext.applyDefaults(childDocument.inputs)
        for input in childDocument.inputs {
            guard let argument = node.arguments[input.name] else {
                continue
            }
            if let binding = argument.binding {
                childContext.bind(input.name, to: context.binding(binding))
            } else if let value = argument.value {
                childContext.unbind(input.name)
                childContext.set(input.name, to: value)
            }
        }
        for action in childDocument.actions {
            if let target = node.actions[action.name] {
                childContext.on(action.name) { context.perform(target, arguments: $0) }
            }
        }
        try validateInputs(childDocument, context: childContext)
        return try renderNode(childDocument.root, context: childContext, scope: identity, source: url, ancestry: ancestry + [url])
    }

    private func validateContent(_ shape: UIContentShape, count: Int, nodeID: String) throws {
        if (shape == .none && count > 0) || (shape == .single && count > 1) {
            throw UIDiagnostic("Invalid child count for \(shape.rawValue) content.", nodeID: nodeID)
        }
    }

    private func factoryContext(
        signature: UIDescriptorSignature,
        arguments: [String: UIArgument],
        actions: [String: String],
        context: UIBindingContext,
        children: [UIRenderedChild],
        nodeID: String
    ) throws -> UIFactoryContext {
        if signature.id != "ForEach", let unknown = arguments.keys.first(where: { key in !signature.parameters.contains { $0.name == key } }) {
            throw UIDiagnostic("Unknown parameter '\(unknown)' on '\(signature.name)'.", nodeID: nodeID)
        }
        var values: [String: UIValue] = [:]
        var bindings: [String: Binding<UIValue>] = [:]
        for parameter in signature.parameters {
            let argument = arguments[parameter.name]
            let value: UIValue?
            if let path = argument?.binding {
                guard let resolved = context.value(path) else {
                    throw UIDiagnostic("Unresolved binding '\(path)'.", nodeID: nodeID)
                }
                value = resolved
            } else {
                value = argument?.value ?? parameter.defaultValue
            }
            if let value {
                guard parameter.type.accepts(value), value.number?.isFinite != false else {
                    throw UIDiagnostic("Invalid '\(parameter.name)'.", nodeID: nodeID)
                }
                values[parameter.name] = value
            } else if argument != nil {
                throw UIDiagnostic("Unresolved binding '\(argument?.binding ?? parameter.name)'.", nodeID: nodeID)
            }
            if parameter.isBinding, let path = argument?.binding {
                bindings[parameter.name] = context.binding(path)
            } else if parameter.isBinding {
                let key = "control/\(nodeID)/\(parameter.name)"
                if context.value(key) == nil {
                    context.set(key, to: value ?? .null)
                }
                bindings[parameter.name] = context.binding(key)
            }
        }
        for (event, target) in actions where signature.id != "ForEach" {
            guard signature.actions.contains(where: { $0.name == event }), context.hasAction(target) else {
                throw UIDiagnostic("Unknown or unresolved action '\(event)' → '\(target)'.", nodeID: nodeID)
            }
        }
        return UIFactoryContext(arguments: values, bindings: bindings, actions: actions, context: context, children: children)
    }
}

@MainActor
public struct UISceneView: View {
    public let session: UISceneInstance
    public init(session: UISceneInstance) { self.session = session }
    public var body: some View {
        session.render()
            .onEvent(UISceneResourceChanged.self) { [weak session] event in
                Task { @MainActor in session?.resourceChanged(event) }
            }
    }
}

extension UIComponent {
    @MainActor
    public init(
        ui path: String,
        context: UIBindingContext = .init(),
        behaviour: Behaviour = .overlay,
        windowRef: WindowRef = .primary,
        resourceRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        catalog: UICatalog = .standard
    ) throws {
        self.init(source: UIComponentSource(kind: .ui, path: path), behaviour: behaviour, windowRef: windowRef)
        let runtime = UIComponentRuntime(resourceRoot: resourceRoot, catalog: catalog)
        runtime.defaultContext = context
        _ = try resolveView(runtime: runtime)
    }
}
