//
//  TextFieldStyle.swift
//  AdaEngine
//

import AdaUtils
import Math

/// A protocol that defines a text field style.
@_typeEraser(AnyTextFieldStyle)
@MainActor public protocol TextFieldStyle: Sendable {
    /// The body of the text field style.
    associatedtype Body: View

    /// Make the body of the text field style.
    ///
    /// - Parameter configuration: The configuration of the text field style.
    /// - Returns: The body of the text field style.
    @ViewBuilder func _body(configuration: TextField) -> Body
}

extension View {
    /// Sets the style for text fields within this view to a text field style with a custom appearance and standard interaction behavior.
    ///
    /// - Parameter style: The text field style to apply.
    /// - Returns: The view with the text field style applied.
    public func textFieldStyle<S: TextFieldStyle>(_ style: S) -> some View {
        self.environment(\.textFieldStyle, style)
    }
}

/// The default text field style.
public struct DefaultTextFieldStyle: TextFieldStyle {
    /// Initialize a new default text field style.
    public init() {}

    public func _body(configuration: TextField) -> some View {
        configuration
            .environment(\._textFieldDrawsBackground, true)
    }
}

/// A text field style that provides a plain appearance.
public struct PlainTextFieldStyle: TextFieldStyle {
    /// Initialize a new plain text field style.
    public init() {}

    public func _body(configuration: TextField) -> some View {
        configuration
            .environment(\._textFieldDrawsBackground, false)
    }
}

struct TextFieldEnvironmentKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any TextFieldStyle = DefaultTextFieldStyle()
}

extension EnvironmentValues {
    public var textFieldStyle: any TextFieldStyle {
        get { return self[TextFieldEnvironmentKey.self] }
        set { self[TextFieldEnvironmentKey.self] = newValue }
    }

    @Entry internal var _isTextFieldPrimitive: Bool = false
    @Entry internal var _textFieldDrawsBackground: Bool = true
}

/// A type-erased text field style.
public struct AnyTextFieldStyle: TextFieldStyle {
    /// The style of the type-erased text field style.
    let style: any TextFieldStyle

    /// Initialize a new type-erased text field style.
    ///
    /// - Parameter style: The style to erase.
    public init<S: TextFieldStyle>(erasing style: S) {
        self.style = style
    }

    /// Make the body of the type-erased text field style.
    ///
    /// - Parameter configuration: The configuration of the type-erased text field style.
    /// - Returns: The body of the type-erased text field style.
    public func _body(configuration: TextField) -> AnyView {
        AnyView(style._body(configuration: configuration))
    }
}
