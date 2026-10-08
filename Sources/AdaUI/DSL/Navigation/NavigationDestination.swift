//
//  NavigationDestination.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2026.
//

import AdaUtils
import Math

extension View {
    /// Associates a destination view with a presented data type for use within
    /// a navigation stack.
    ///
    /// Add this modifier to a view inside a ``NavigationStack`` to describe the view
    /// that the stack displays when presenting a particular kind of data.
    ///
    /// ```swift
    /// NavigationStack {
    ///     ContentView()
    ///         .navigate(for: String.self) { value in
    ///             DetailView(message: value)
    ///         }
    /// }
    /// ```
    public func navigate<D: Hashable, Destination: View>(
        for type: D.Type,
        @ViewBuilder destination: @escaping (D) -> Destination
    ) -> some View {
        modifier(NavigationDestinationModifier(content: self, type: type, destination: destination))
    }
}

struct NavigationDestinationModifier<WrappedContent: View, D: Hashable, Destination: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: WrappedContent
    let type: D.Type
    let destination: (D) -> Destination

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let contentNode = context.makeNode(from: content)
        let node = NavigationDestinationNode(
            contentNode: contentNode,
            content: content,
            type: type,
            destination: destination,
            inputs: context
        )
        return node
    }
}

final class NavigationDestinationNode<D: Hashable, Destination: View>: ViewModifierNode {
    private let type: D.Type
    private let destination: (D) -> Destination
    private var viewInputs: _ViewInputs

    init<Content: View>(
        contentNode: ViewNode,
        content: Content,
        type: D.Type,
        destination: @escaping (D) -> Destination,
        inputs: _ViewInputs
    ) {
        self.type = type
        self.destination = destination
        self.viewInputs = inputs
        super.init(contentNode: contentNode, content: content)
        registerDestination(in: inputs.environment)
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        super.updateEnvironment(environment)
        viewInputs.environment = environment
        registerDestination(in: environment)
    }

    private func registerDestination(in environment: EnvironmentValues) {
        let builder: (D, _ViewInputs) -> ViewNode = { [destination] (value: D, inputs: _ViewInputs) in
            let view = destination(value)
            return Destination._makeView(_ViewGraphNode(value: view), inputs: inputs).node
        }

        environment.navigationSplitColumnContext?.registerDestination(for: type, builder: builder)
        registerDestinationInAncestorSplit(builder: builder)

        guard let context = environment.navigationContext else {
            return
        }
        context.registerDestination(for: type, builder: builder)
    }

    private func registerDestinationInAncestorSplit(builder: @escaping (D, _ViewInputs) -> ViewNode) {
        var current = parent
        while let node = current {
            if let registrar = node as? NavigationSplitDestinationRegistering {
                registrar.registerDestinationBuilder(for: ObjectIdentifier(type)) { anyValue, inputs in
                    guard let typedValue = anyValue.base as? D else {
                        return nil
                    }
                    return builder(typedValue, inputs)
                }
                return
            }
            current = node.parent
        }
    }
}
