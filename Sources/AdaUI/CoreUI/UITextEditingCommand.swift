/// An editing operation that can be sent to the currently focused text control.
public enum UITextEditingCommand: Sendable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
}

/// A view container capable of applying editing commands to its focused control.
@MainActor
public protocol UITextEditingCommandHandling: AnyObject {
    @discardableResult
    func uiPerformTextEditingCommand(_ command: UITextEditingCommand) -> Bool
}

extension UIContainerView: UITextEditingCommandHandling {
    @discardableResult
    public func uiPerformTextEditingCommand(_ command: UITextEditingCommand) -> Bool {
        if let textEditor = focusManager.focusedNode as? TextEditorViewNode {
            textEditor.perform(command)
            return true
        }

        if let textField = focusManager.focusedNode as? TextFieldViewNode {
            textField.perform(command)
            return true
        }

        return false
    }
}

extension UIWindow {
    /// Applies an editing command to the focused text control in this window.
    @discardableResult
    public func uiPerformTextEditingCommand(_ command: UITextEditingCommand) -> Bool {
        func perform(in view: UIView) -> Bool {
            if let handler = view as? any UITextEditingCommandHandling,
                handler.uiPerformTextEditingCommand(command) {
                return true
            }

            for subview in view.subviews where perform(in: subview) {
                return true
            }
            return false
        }

        return subviews.contains { perform(in: $0) }
    }
}

extension TextEditorViewNode {
    func perform(_ command: UITextEditingCommand) {
        switch command {
        case .undo: undo()
        case .redo: redo()
        case .cut: cutSelection()
        case .copy: copySelection()
        case .paste: pasteText()
        case .selectAll: selectAll()
        }
    }
}

extension TextFieldViewNode {
    func perform(_ command: UITextEditingCommand) {
        switch command {
        case .undo: undo()
        case .redo: redo()
        case .cut: cutSelection()
        case .copy: copySelection()
        case .paste: pasteText()
        case .selectAll: selectAll()
        }
    }
}
