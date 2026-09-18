//
//  ZStack.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 08.06.2024.
//

/// A view that overlays its subviews, aligning them in both axes.
/// The ZStack assigns each successive subview a higher z-axis value than the one before it, meaning later subviews appear “on top” of earlier ones.
public struct ZStack<Content: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let anchor: AnchorPoint
    let content: () -> Content

    /// Creates an instance with the given alignment.
    /// - Parameter anchpr: The guide for aligning the subviews in this stack on both the x- and y-axes.
    /// - Parameter content: A view builder that creates the content of this stack.
    public init(anchor: AnchorPoint = .center, @ViewBuilder content: @escaping () -> Content) {
        self.anchor = anchor
        self.content = content
    }

    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let content = view[\.content]
        let stack = view.value

        let node = LayoutViewContainerNode(
            layout: ZStackLayout(anchor: stack.anchor),
            content: content.value
        )

        node.updateEnvironment(inputs.environment)
        node.invalidateContent()

        return _ViewOutputs(node: node)
    }

    @MainActor @preconcurrency
    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let node = Self._makeView(view, inputs: inputs.input)
        return _ViewListOutputs(outputs: [node])
    }
}
