//
//  AnyView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

/// A type-erased view.
///
/// An ``AnyView`` allows changing the type of view used in a given view hierarchy.
/// Whenever the type of view used with an AnyView changes, the old hierarchy is destroyed
/// and a new hierarchy is created for the new type.
@frozen public struct AnyView: View {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let content: any View

    /// Create an instance that type-erases view.
    public init<T: View>(_ view: T) {
        self.content = view
    }

    /// Create an instance that type-erases view.
    public init<V: View>(erasing view: V) {
        self.content = view
    }

    @MainActor @preconcurrency
    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let content = view[\.content].value
        return self.makeView(content, inputs: inputs)
    }

    @MainActor @preconcurrency
    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let content = view[\.content].value
        return self.makeListView(content, inputs: inputs)
    }

    @MainActor @preconcurrency
    private static func makeView<T: View>(_ view: T, inputs: _ViewInputs) -> _ViewOutputs {
        T._makeView(_ViewGraphNode(value: view), inputs: inputs)
    }

    @MainActor @preconcurrency
    private static func makeListView<T: View>(_ view: T, inputs: _ViewListInputs) -> _ViewListOutputs {
        T._makeListView(_ViewGraphNode(value: view), inputs: inputs)
    }
}
