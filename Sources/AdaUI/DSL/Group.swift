//
//  Group.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 01.08.2024.
//

/// Combine views and can apply modifiers for all subviews.
///
/// - Warning: Works currently with environment modifiers.
public struct Group<Content: View>: View {
    public let content: Content
    public var body: Never { fatalError("Unreachable code") }

    @inlinable
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @MainActor @preconcurrency
    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let content = view[\.content]

        let node = LayoutViewContainerNode(
            layout: inputs.layout,
            content: { content.value }
        )
        node.isVirtual = true
        node.updateEnvironment(inputs.environment)
        node.invalidateContent()

        return _ViewOutputs(node: node)
    }

    @MainActor @preconcurrency
    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let content = view[\.content]
        let inputs = inputs.input.resolveStorages(in: content.value)
        return Content._makeListView(content, inputs: _ViewListInputs(input: inputs))
    }
}
