//
//  ViewModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

/// A modifier that you apply to a view or another view modifier, producing a different version of the original value.
///
/// Adopt the ``ViewModifier`` protocol when you want to create a reusable modifier that you can apply to any view.
/// You can apply ``View/modifier(_:)`` directly to a view, but a more common and idiomatic approach
/// uses ``View/modifier(_:)`` to define an extension to View itself that incorporates the view modifier:
@preconcurrency
public protocol ViewModifier {
    /// The type of view representing the body.
    associatedtype Body: View
    /// The content view type passed to body().
    typealias Content = _ModifiedContent<Self>

    /// Gets the current body of the caller.
    @MainActor
    @ViewBuilder
    func body(content: Self.Content) -> Body

    @MainActor static func _makeView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs

    @MainActor static func _makeListView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs
}

extension ViewModifier {
    @MainActor
    public static func _makeView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        if let builder = modifier.value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: inputs)
            node.updateEnvironment(inputs.environment)
            return _ViewOutputs(node: node)
        }
        let newBody = modifier.value.body(content: _ModifiedContent(storage: .makeView(body)))
        return Self.Body._makeView(_ViewGraphNode(value: newBody), inputs: inputs)
    }

    @MainActor
    public static func _makeListView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        if let builder = modifier.value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: inputs.input)
            node.updateEnvironment(inputs.input.environment)
            let output = _ViewOutputs(node: node)
            return _ViewListOutputs(outputs: [output])
        }
        let newBody = modifier.value.body(content: _ModifiedContent(storage: .makeViewList(body)))
        return Self.Body._makeListView(_ViewGraphNode(value: newBody), inputs: inputs)
    }
}

extension ViewModifier {
    /// Returns a new modifier that is the result of concatenating
    /// `self` with `modifier`.
    @inlinable public func concat<T>(_ modifier: T) -> ModifiedContent<Self, T> {
        ModifiedContent(content: self, modifier: modifier)
    }
}

extension View {
    /// Applies a modifier to a view and returns a new view.
    /// - Parameter modifier: The modifier to apply to this view.
    public func modifier<T>(_ modifier: T) -> ModifiedContent<Self, T> {
        return ModifiedContent(content: self, modifier: modifier)
    }
}

/// A modified content.
public struct ModifiedContent<Content, Modifier> {
    // Built-in modifiers also retain their input view. Keeping this pair indirect
    // prevents each modifier from doubling the inline size of the entire chain
    // and exhausting the device's stack during view graph construction.
    @usableFromInline
    var storage: Storage

    /// The content.
    public var content: Content {
        get { storage.content }
        set { storage = Storage(content: newValue, modifier: storage.modifier) }
    }
    /// The modifier.
    public var modifier: Modifier {
        get { storage.modifier }
        set { storage = Storage(content: storage.content, modifier: newValue) }
    }

    /// Initialize a new modified content.
    ///
    /// - Parameter content: The content.
    /// - Parameter modifier: The modifier.
    @inlinable public init(content: Content, modifier: Modifier) {
        self.storage = Storage(content: content, modifier: modifier)
    }

    // Immutable storage preserves value semantics when a copied ModifiedContent
    // is mutated, including mutations through writable key paths.
    @usableFromInline
    final class Storage {
        let content: Content
        let modifier: Modifier

        @usableFromInline
        init(content: Content, modifier: Modifier) {
            self.content = content
            self.modifier = modifier
        }
    }
}

extension ViewModifier where Body == Never {
    /// The body of the modifier.
    ///
    /// - Parameter content: The content.
    /// - Returns: The body of the modifier.
    public func body(content _: Self.Content) -> Never {
        fatalError("We should call body when Body is Never type.")
    }
}

/// A modified content.
public struct _ModifiedContent<Content: ViewModifier>: View {
    /// The body type.
    public typealias Body = Never
    /// The body of the modifier.
    public var body: Never { fatalError("Unreachable code") }

    enum Storage {
        case makeView((_ViewInputs) -> _ViewOutputs)
        case makeViewList((_ViewListInputs) -> _ViewListOutputs)
    }

    let storage: Storage

    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let storage = view[\.storage].value
        switch storage {
        case let .makeView(block):
            return block(inputs)
        case let .makeViewList(block):
            let nodes = block(_ViewListInputs(input: inputs)).outputs.map(\.node)
            let node = LayoutViewContainerNode(
                layout: inputs.layout,
                content: view.value,
                nodes: nodes
            )
            node.updateEnvironment(inputs.environment)
            inputs.registerNodeForStorages(node)
            return _ViewOutputs(node: node)
        }
    }

    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let storage = view[\.storage].value
        switch storage {
        case let .makeViewList(block):
            return block(inputs)
        default:
            fatalError("Unreachable code")
        }
    }
}

// MARK: - Internal

extension ModifiedContent: View where Modifier: ViewModifier, Content: View {
    public var body: Never {
        fatalError("Unreachable code")
    }

    @MainActor
    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        return Modifier._makeView(for: view[\.modifier], inputs: inputs) { inputs in
            return Content._makeView(view[\.content], inputs: inputs)
        }
    }

    @MainActor
    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        return Modifier._makeListView(for: view[\.modifier], inputs: inputs) { inputs in
            let content = view[\.content]
            if let builder = content.value as? ViewNodeBuilder {
                let node = builder.buildViewNode(in: inputs.input)
                node.updateEnvironment(inputs.input.environment)
                let output = _ViewOutputs(node: node)
                return _ViewListOutputs(outputs: [output])
            }

            return Content._makeListView(content, inputs: inputs)
        }
    }
}

extension ModifiedContent: ViewModifier where Content: ViewModifier, Modifier: ViewModifier {
    @MainActor
    public static func _makeView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        return Modifier._makeView(for: modifier[\.modifier], inputs: inputs) { inputs in
            let content = modifier[\.content]
            return Content._makeView(for: content, inputs: inputs, body: body)
        }
    }

    @MainActor
    public static func _makeListView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        return Modifier._makeListView(for: modifier[\.modifier], inputs: inputs) { inputs in
            let content = modifier[\.content]
            return Content._makeListView(for: content, inputs: inputs, body: body)
        }
    }
}

protocol _ViewInputsViewModifier {
    @MainActor static func _makeModifier(_ modifier: _ViewGraphNode<Self>, inputs: inout _ViewInputs)
}

extension ViewModifier where Self: _ViewInputsViewModifier {
    @MainActor
    static func _makeView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        var inputs = inputs
        Self._makeModifier(modifier, inputs: &inputs)

        let outputs: _ViewOutputs
        if let builder = modifier.value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: inputs)
            outputs = _ViewOutputs(node: node)
        } else {
            let newBody = modifier.value.body(content: _ModifiedContent(storage: .makeView(body)))
            outputs = Self.Body._makeView(_ViewGraphNode(value: newBody), inputs: inputs)
        }

        // Store the accumulated environment transform on the resulting node so it can
        // re-apply its overrides lazily when the parent environment changes. Nested
        // environment modifiers have already stored a more specific transform on the
        // node, so preserve it instead of replacing inner overrides.
        if outputs.node.environmentTransform == nil,
            let transform = inputs.pendingEnvironmentTransform {
            outputs.node.environmentTransform = transform
        }
        outputs.node.updateEnvironment(inputs.environment)

        return outputs
    }

    /// List builds (e.g. ``LayoutViewContainerNode`` / ``ViewContainerNode`` via ``invalidateContent``)
    /// must apply the same input-side environment mutations as ``_makeView``; otherwise modifiers
    /// like ``TransformViewEnvironmentModifier`` never run ``_makeModifier`` and values such as
    /// ``View/environment(_:)`` for observables are missing for descendants.
    @MainActor
    static func _makeListView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        var input = inputs.input
        Self._makeModifier(modifier, inputs: &input)

        if let builder = modifier.value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: input)
            node.updateEnvironment(input.environment)
            return _ViewListOutputs(outputs: [_ViewOutputs(node: node)])
        }

        let newBody = modifier.value.body(content: _ModifiedContent(storage: .makeViewList(body)))
        let outputs = Self.Body._makeListView(_ViewGraphNode(value: newBody), inputs: _ViewListInputs(input: input))
        if let transform = input.pendingEnvironmentTransform {
            for index in outputs.outputs.indices {
                if outputs.outputs[index].node.environmentTransform == nil {
                    outputs.outputs[index].node.environmentTransform = transform
                }
                outputs.outputs[index].node.updateEnvironment(input.environment)
            }
        }
        return outputs
    }
}

protocol _ViewOutputsViewModifier {
    @MainActor static func _makeModifier(_ modifier: _ViewGraphNode<Self>, outputs: inout _ViewOutputs)
}

extension ViewModifier where Self: _ViewOutputsViewModifier {
    @MainActor
    static func _makeView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        if let builder = modifier.value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: inputs)
            return _ViewOutputs(node: node)
        }
        let newBody = modifier.value.body(content: _ModifiedContent(storage: .makeView(body)))
        var outputs = Self.Body._makeView(_ViewGraphNode(value: newBody), inputs: inputs)
        self._makeModifier(modifier, outputs: &outputs)
        return outputs
    }

    @MainActor
    static func _makeListView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        if let builder = modifier.value as? ViewNodeBuilder {
            let node = builder.buildViewNode(in: inputs.input)
            var output = _ViewOutputs(node: node)
            self._makeModifier(modifier, outputs: &output)
            return _ViewListOutputs(outputs: [output])
        }

        let newBody = modifier.value.body(content: _ModifiedContent(storage: .makeViewList(body)))
        var outputs = Self.Body._makeListView(_ViewGraphNode(value: newBody), inputs: inputs)
        for index in outputs.outputs.indices {
            self._makeModifier(modifier, outputs: &outputs.outputs[index])
        }
        return outputs
    }
}
