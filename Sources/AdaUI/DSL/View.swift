//
//  View.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

/// A type that represents part of your user interface and provides modifiers that you use to configure views.
@_typeEraser(AnyView)
@MainActor @preconcurrency
public protocol View {
    /// The type of view representing the body of this view.
    associatedtype Body: View

    /// The content and behavior of the view.
    @ViewBuilder @MainActor @preconcurrency
    var body: Self.Body { get }

    @MainActor @preconcurrency static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs
    @MainActor @preconcurrency static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs
}

extension View {
    @MainActor @preconcurrency
    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let stateContainer = inputs.requiresStateContainer(for: view.value) ? ViewStateContainer() : nil
        let resolvedInputs = inputs.resolveStorages(in: view.value, stateContainer: stateContainer)

        if let builder = view.value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: inputs)
            node.updateEnvironment(inputs.environment)
            node.stateContainer = stateContainer
            resolvedInputs.registerNodeForStorages(node)
            return _ViewOutputs(node: node)
        }

        // Inspect the type before evaluating body. A non-builder body is evaluated
        // by the observed container below; evaluating it here as well duplicates
        // work and subscribes an observing ancestor to the child's dependencies.
        // Class bodies retain the dynamic check for builder-conforming subclasses.
        if resolvedInputs.propertyStorages.isEmpty,
            Self.Body.self is any ViewNodeBuilder.Type || Self.Body.self is AnyClass,
            let builder = view[\.body].value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: inputs)
            node.updateEnvironment(inputs.environment)
            node.stateContainer = stateContainer
            resolvedInputs.registerNodeForStorages(node)
            return _ViewOutputs(node: node)
        } else {
            let node = LayoutViewContainerNode(
                layout: AnyLayout(inputs.layout),
                content: view.value,
                bypassSingleChildLayout: true,
                buildImmediately: false,
                body: { inputs in
                    let body = _ViewGraphNode(value: view.value)[\.body]
                    return Self.Body._makeListView(body, inputs: inputs)
                }
            )
            node.updateEnvironment(inputs.environment)
            node.stateContainer = stateContainer
            resolvedInputs.registerNodeForStorages(node)
            node.invalidateContent()
            return _ViewOutputs(node: node)
        }
    }

    @MainActor @preconcurrency
    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let stateContainer = inputs.input.requiresStateContainer(for: view.value) ? ViewStateContainer() : nil
        let resolvedInputs = inputs.input.resolveStorages(in: view.value, stateContainer: stateContainer)

        if let builder = view.value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: inputs.input)
            node.updateEnvironment(inputs.input.environment)
            node.stateContainer = stateContainer
            resolvedInputs.registerNodeForStorages(node)
            return _ViewListOutputs(outputs: [_ViewOutputs(node: node)])
        }

        if stateContainer != nil {
            let node = LayoutViewContainerNode(
                layout: AnyLayout(inputs.input.layout),
                content: view.value,
                bypassSingleChildLayout: true,
                buildImmediately: false,
                body: { inputs in
                    let body = _ViewGraphNode(value: view.value)[\.body]
                    return Self.Body._makeListView(body, inputs: inputs)
                }
            )
            node.updateEnvironment(inputs.input.environment)
            node.stateContainer = stateContainer
            resolvedInputs.registerNodeForStorages(node)
            node.invalidateContent()
            return _ViewListOutputs(outputs: [_ViewOutputs(node: node)])
        }

        let body = view[\.body]
        if let builder = body.value as? ViewNodeBuilder, resolvedInputs.propertyStorages.isEmpty {
            let node = builder.buildViewNode(in: inputs.input)
            node.updateEnvironment(inputs.input.environment)
            node.stateContainer = stateContainer
            resolvedInputs.registerNodeForStorages(node)
            return _ViewListOutputs(outputs: [_ViewOutputs(node: node)])
        }

        let inputs = inputs.input.resolveStorages(in: body.value)
        return Self.Body._makeListView(body, inputs: _ViewListInputs(input: inputs))
    }
}

extension View where Body == Never {
    package var body: Never {
        fatalError("Unreachable code")
    }
}

extension Never {
    public typealias Body = Never

    public var body: Never {
        fatalError("Unreachable code")
    }
}

extension Never: View {}

extension Optional: View where Wrapped: View {
    public var body: some View {
        switch self {
        case .none:
            EmptyView()
        case let .some(wrapped):
            wrapped
        }
    }
}

// MARK: - Debug

extension View {
    @MainActor
    public static func _printChanges() {
        ViewGraph.registerViewToDebugUpdate(self)
    }
}
