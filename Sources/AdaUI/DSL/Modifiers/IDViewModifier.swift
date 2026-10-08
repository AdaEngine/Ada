//
//  IDViewModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 26.07.2024.
//

extension View {
    /// Binds a view’s identity to the given proxy value.
    public func id<H: Hashable>(_ identifier: H) -> some View {
        IDView(id: identifier, content: self)
    }
}

final class IDViewNodeModifier: ViewModifierNode {
    var identifier: AnyHashable?

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? IDViewNodeModifier else {
            super.update(from: newNode)
            return
        }

        self.identifier = other.identifier
        super.update(from: newNode)
    }

    override func findNodeById(_ id: AnyHashable) -> ViewNode? {
        return id == self.identifier ? self : nil
    }
}

struct IDView<V: View>: View, ViewNodeBuilder {
    typealias Body = Never

    let id: AnyHashable
    let content: V

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = IDViewNodeModifier(contentNode: context.makeNode(from: content), content: content)
        node.identifier = id
        return node
    }
}

extension View {
    /// Uses the string you specify to identify the view.
    public func accessibilityIdentifier(_ identifier: String) -> some View {
        modifier(AccessibilityAttachmentModifier(identifier: identifier))
    }
}

/// A view modifier that adds accessibility properties to the view
struct AccessibilityAttachmentModifier: ViewModifier, _ViewOutputsViewModifier {
    let identifier: String

    func body(content: Content) -> some View {
        return content
    }

    static func _makeView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewInputs,
        body: @escaping (_ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        let newBody = modifier.value.body(content: _ModifiedContent(storage: .makeView(body)))
        var outputs = Body._makeView(_ViewGraphNode(value: newBody), inputs: inputs)
        _makeModifier(modifier, outputs: &outputs)
        return outputs
    }

    static func _makeListView(
        for modifier: _ViewGraphNode<Self>,
        inputs: _ViewListInputs,
        body: @escaping (_ViewListInputs) -> _ViewListOutputs
    ) -> _ViewListOutputs {
        let newBody = modifier.value.body(content: _ModifiedContent(storage: .makeViewList(body)))
        var outputs = Body._makeListView(_ViewGraphNode(value: newBody), inputs: inputs)
        for index in outputs.outputs.indices {
            _makeModifier(modifier, outputs: &outputs.outputs[index])
        }
        return outputs
    }

    static func _makeModifier(_ modifier: _ViewGraphNode<Self>, outputs: inout _ViewOutputs) {
        outputs.node.accessibilityIdentifier = modifier[\.identifier].value
    }
}
