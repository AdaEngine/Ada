//
//  TextField.swift
//  AdaEngine
//
//  Created by Codex on 19.02.2026.
//

import AdaInput

/// A control that displays an editable text interface.
public struct TextField: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let placeholder: String
    let text: Binding<String>
    let onSubmit: (() -> Void)?
    var keyHandler: ((KeyEvent) -> Bool)?
    var caretChanged: ((Int) -> Void)?

    /// Handles completion/navigation keys before the field's default editing behavior.
    public func onKeyPress(_ handler: @escaping (KeyEvent) -> Bool) -> Self {
        var copy = self
        copy.keyHandler = handler
        return copy
    }

    /// Reports the caret as a grapheme offset, including mouse and keyboard movement.
    public func onCaretChange(_ handler: @escaping (Int) -> Void) -> Self {
        var copy = self
        copy.caretChanged = handler
        return copy
    }

    /// Creates a text field with an optional placeholder.
    ///
    /// - Parameters:
    ///   - placeholder: Text displayed when the field is empty.
    ///   - text: Two-way binding for the field content.
    public init(_ placeholder: String = "", text: Binding<String>) {
        self.init(placeholder, text: text, onSubmit: nil)
    }

    /// Creates a text field that submits when Return is pressed while it has focus.
    public init(_ placeholder: String = "", text: Binding<String>, onSubmit: (() -> Void)?) {
        self.placeholder = placeholder
        self.text = text
        self.onSubmit = onSubmit
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        if context.environment._isTextFieldPrimitive {
            return TextFieldViewNode(inputs: context, content: self)
        } else {
            let viewInputs = context
            let style = viewInputs.environment.textFieldStyle
            let inputs = viewInputs.resolveStorages(in: style)
            let body = AnyView(
                style._body(configuration: self)
                    .environment(\._isTextFieldPrimitive, true)
            )
            return AnyTextFieldStyle.Body._makeView(_ViewGraphNode(value: body), inputs: inputs).node
        }
    }
}
