//
//  HStack.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

import Observation

/// A view that arranges its subviews in a horizontal line.
public struct HStack<Content: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let alignment: VerticalAlignment
    let spacing: Float?
    let content: () -> Content

    /// Creates a horizontal stack with the given spacing and vertical alignment.
    /// - Parameter alignment: The guide for aligning the subviews in this stack. This guide has the same vertical screen coordinate for every subview.
    /// - Parameter spacing: The distance between adjacent subviews, or nil if you want the stack to choose a default distance for each pair of subviews.
    /// - Parameter content: A view builder that creates the content of this stack.
    public init(
        alignment: VerticalAlignment = .center,
        spacing: Float? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let content = view[\.content]
        let stack = view.value

        let node = LayoutViewContainerNode(
            layout: HStackLayout(alignment: stack.alignment, spacing: stack.spacing),
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
