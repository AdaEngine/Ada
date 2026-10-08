//
//  ViewTuple.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

/// A View created from a swift tuple of View values.
@MainActor
@frozen @preconcurrency
public struct ViewTuple<Content>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    public let value: Content

    public init(value: Content) {
        self.value = value
    }

    @MainActor
    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let listInputs = _ViewListInputs(input: inputs)
        let outputs = Self._makeListView(view, inputs: listInputs)

        let node = LayoutViewContainerNode(
            layout: inputs.layout,
            content: view.value,
            nodes: outputs.outputs.map(\.node)
        )
        node.isVirtual = true
        node.updateEnvironment(inputs.environment)
        inputs.registerNodeForStorages(node)
        return _ViewOutputs(node: node)
    }

    @MainActor
    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        // swiftlint:disable:next syntactic_sugar
        let outputs = Array<any View>.fromTuple(view.value.value)
            .map {
                Self.makeView($0, inputs: inputs.input)
            }
        return _ViewListOutputs(outputs: outputs)
    }

    @MainActor
    private static func makeView<V: View>(_ view: V, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.resolveStorages(in: view)
        return V._makeView(_ViewGraphNode(value: view), inputs: inputs)
    }
}

@MainActor
protocol AnyViewTuple {}

extension ViewTuple: AnyViewTuple {}

extension Array {
    static func fromTuple<Tuple>(_ tuple: Tuple) -> [Element] {
        return Mirror(reflecting: tuple).children.compactMap { $0.value as? Element }
    }
}
