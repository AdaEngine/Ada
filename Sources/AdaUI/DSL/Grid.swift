//
//  Grid.swift
//  AdaEngine
//

/// A view that arranges its subviews in a two-dimensional grid.
public struct Grid<Content: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    private let columns: Int
    private let horizontalSpacing: Float?
    private let verticalSpacing: Float?
    private let alignment: Alignment
    private let content: () -> Content

    public init(
        columns: Int,
        horizontalSpacing: Float? = nil,
        verticalSpacing: Float? = nil,
        alignment: Alignment = .topLeading,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.columns = columns
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.alignment = alignment
        self.content = content
    }

    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let content = view[\.content]
        let grid = view.value

        let node = LayoutViewContainerNode(
            layout: GridLayout(
                columns: grid.columns,
                horizontalSpacing: grid.horizontalSpacing,
                verticalSpacing: grid.verticalSpacing,
                alignment: grid.alignment
            ),
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
