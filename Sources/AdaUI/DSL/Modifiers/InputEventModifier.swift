//
//  InputEventModifier.swift
//  AdaEngine
//
//  Created by OpenAI Codex on 30.04.2026.
//

import AdaInput

extension View {
    /// Runs an action when the view tree receives a matching input event.
    public func onInputEvent<E: InputEvent>(
        _: E.Type,
        perform action: @escaping @MainActor (E) -> Void
    ) -> some View {
        self.modifier(InputEventModifier(content: self, action: action))
    }
}

struct InputEventModifier<Content: View, E: InputEvent>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let action: @MainActor (E) -> Void

    func buildViewNode(in context: BuildContext) -> ViewNode {
        InputEventModifierNode(
            contentNode: context.makeNode(from: content),
            content: content,
            action: action
        )
    }
}

private final class InputEventModifierNode<E: InputEvent>: ViewModifierNode {
    private let action: @MainActor (E) -> Void

    init<Content: View>(
        contentNode: ViewNode,
        content: Content,
        action: @escaping @MainActor (E) -> Void
    ) {
        self.action = action
        super.init(contentNode: contentNode, content: content)
    }

    override func onReceiveEvent(_ event: any InputEvent) {
        if let event = event as? E {
            action(event)
        }
        contentNode.onReceiveEvent(event)
    }
}
