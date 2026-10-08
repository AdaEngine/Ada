import AdaInput
import Math

extension View {
    /// Observes the start of a primary click or touch while preserving nested controls' input and focus.
    public func onPrimaryInteraction(perform action: @escaping () -> Void) -> some View {
        modifier(PrimaryInteractionModifier(content: self, action: action))
    }
}

private struct PrimaryInteractionModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never
    let content: Content
    let action: () -> Void

    func buildViewNode(in context: BuildContext) -> ViewNode {
        PrimaryInteractionNode(contentNode: context.makeNode(from: content), content: content, action: action)
    }
}

private final class PrimaryInteractionNode: ViewModifierNode {
    private var action: () -> Void

    init<Content: View>(contentNode: ViewNode, content: Content, action: @escaping () -> Void) {
        self.action = action
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        if let node = newNode as? PrimaryInteractionNode {
            action = node.action
        }
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard let target = super.hitTest(point, with: event) else {
            return nil
        }
        // Observe before dispatch, returning the original target so text focus, buttons and drags remain intact.
        if let mouse = event as? MouseEvent, mouse.button == .left, mouse.phase == .began {
            action()
        } else if let touch = event as? TouchEvent, touch.phase == .began {
            action()
        }
        return target
    }
}
