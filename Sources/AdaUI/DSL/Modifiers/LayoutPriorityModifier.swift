//
//  LayoutPriorityModifier.swift
//  AdaEngine
//
//  Created by OpenAI on 29.04.2026.
//

extension View {
    /// Sets the priority by which a parent layout apportions space to this view.
    public func layoutPriority(_ value: Double) -> some View {
        modifier(LayoutPriorityModifier(content: self, priority: value))
    }
}

struct LayoutPriorityModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let priority: Double

    func buildViewNode(in context: BuildContext) -> ViewNode {
        LayoutPriorityViewNode(
            priority: priority,
            contentNode: context.makeNode(from: content),
            content: content
        )
    }
}

final class LayoutPriorityViewNode: ViewModifierNode {
    private var priority: Double

    override var layoutPriority: Double {
        priority
    }

    init<Content: View>(
        priority: Double,
        contentNode: ViewNode,
        content: Content
    ) {
        self.priority = priority
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? LayoutPriorityViewNode else {
            super.update(from: newNode)
            return
        }

        if self.priority != other.priority {
            Self.recordLayoutMutationRequiringAncestorPass()
        }
        self.priority = other.priority
        super.update(from: newNode)
    }
}
