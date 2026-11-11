import Math

/// A single-value selector presented by the platform menu host. The supplied
/// label is an actual Button, retaining ordinary pointer, touch and focus states.
public struct DropDown<Label: View>: View, ViewNodeBuilder {
    public typealias Option = ChoicePicker.Option
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }
    private let selection: Binding<String>
    private let options: [Option]
    private let identifier: String
    private let label: Label

    /// Option labels are already localized display text; values are stable identities.
    public init(selection: Binding<String>, options: [Option], identifier: String = "", @ViewBuilder label: () -> Label) {
        self.selection = selection; self.options = options; self.identifier = identifier; self.label = label()
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let controller = DropDownController(selection: selection, options: options)
        let button = Button(action: { controller.present() }) { label }.accessibilityIdentifier(identifier)
        let node = DropDownNode(contentNode: context.makeNode(from: button), content: self, controller: controller)
        controller.node = node
        return node
    }
}

@MainActor
private final class DropDownController {
    weak var node: ViewNode?
    let selection: Binding<String>
    let options: [ChoicePicker.Option]
    init(selection: Binding<String>, options: [ChoicePicker.Option]) { self.selection = selection; self.options = options }

    func present() {
        guard let node, node.environment.isEnabled, !options.isEmpty, let present = ContextMenuPresentationCenter.present else { return }
        let frame = node.visualAbsoluteFrame()
        let anchor = Point(frame.minX, frame.maxY)
        let owner = node.owner as? UIView
        let selection = selection
        present(.init(sourceWindow: node.owner?.window, location: owner?.convert(anchor, to: owner?.window) ?? anchor,
            items: options.enumerated().map { index, option in
                .init(id: index, title: option.label, action: { selection.wrappedValue = option.value }, isSelected: selection.wrappedValue == option.value)
            }, isSelectionMenu: true))
    }
}

private final class DropDownNode: ViewModifierNode {
    private var controller: DropDownController
    init<Content: View>(contentNode: ViewNode, content: Content, controller: DropDownController) {
        self.controller = controller
        super.init(contentNode: contentNode, content: content)
    }
    override func update(from newNode: ViewNode) {
        guard let other = newNode as? DropDownNode else { return }
        super.update(from: other)
        // The reconciled button's action captures the new controller. Anchor it
        // to the retained node, rather than the temporary node built for update.
        controller = other.controller
        controller.node = self
    }
}
