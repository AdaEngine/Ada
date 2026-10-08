//
//  TransformViewEnvironmentModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

import AdaUtils

extension View {
    /// Transforms the environment value of the specified key path with the given function.
    /// - Parameter keyPath: A key path that indicates the property of the EnvironmentValues structure to update.
    /// - Parameter transform: The transform block witch update value to set for the item specified by keyPath.
    /// - Returns: A view that has the given value set in its environment.
    public func transformEnvironment<Value>(
        _ keyPath: WritableKeyPath<EnvironmentValues, Value>,
        transform: @escaping (inout Value) -> Void
    ) -> some View {
        self.modifier(
            TransformViewEnvironmentModifier(
                content: self,
                keyPath: keyPath,
                block: transform
            )
        )
    }

    /// Sets the environment value of the specified key path to the given value.
    /// - Parameter keyPath: A key path that indicates the property of the EnvironmentValues structure to update.
    /// - Parameter value: The new value to set for the item specified by keyPath.
    /// - Returns: A view that has the given value set in its environment.
    public func environment<Value>(
        _ keyPath: WritableKeyPath<EnvironmentValues, Value>,
        _ newValue: Value
    ) -> some View {
        self.modifier(
            TransformViewEnvironmentModifier(
                content: self,
                keyPath: keyPath,
                block: { value in
                    value = newValue
                }
            )
        )
    }
}

struct TransformViewEnvironmentModifier<WrappedView: View, Value>: ViewModifier, _ViewInputsViewModifier {
    let content: WrappedView
    let keyPath: WritableKeyPath<EnvironmentValues, Value>
    let block: (inout Value) -> Void

    func body(content: Content) -> some View {
        return content
    }

    static func _makeModifier(_ modifier: _ViewGraphNode<Self>, inputs: inout _ViewInputs) {
        let keyPath = modifier.value.keyPath
        let block = modifier.value.block

        // Apply immediately so child nodes see the updated environment during _makeView.
        block(&inputs.environment[keyPath: keyPath])

        // Accumulate transform for lazy re-application on environment updates.
        // Multiple chained .environment() modifiers compose left-to-right.
        let previous = inputs.pendingEnvironmentTransform
        inputs.pendingEnvironmentTransform = { env in
            previous?(&env)
            block(&env[keyPath: keyPath])
        }
    }
}
