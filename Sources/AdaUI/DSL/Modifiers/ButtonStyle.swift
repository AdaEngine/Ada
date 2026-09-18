//
//  ButtonStyle.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 01.07.2024.
//

import AdaUtils
import Math

/// A protocol that defines a button style.
@_typeEraser(AnyButtonStyle)
@MainActor public protocol ButtonStyle: Sendable {
    /// The body of the button style.
    associatedtype Body: View

    /// The configuration of the button style.
    typealias Configuration = ButtonStyleConfiguration

    /// Make the body of the button style.
    ///
    /// - Parameter configuration: The configuration of the button style.
    /// - Returns: The body of the button style.
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// The properties of a button.
public struct ButtonStyleConfiguration {
    /// The label of the button style.
    public struct Label: View {
        /// The body of the label.
        public typealias Body = Never
        public var body: Never { fatalError("Unreachable code") }

        /// The storage of the label.
        enum Storage {
            case makeView((_ViewInputs) -> _ViewOutputs)
            case makeViewList((_ViewListInputs) -> _ViewListOutputs)
        }

        /// The storage of the label.
        let storage: Storage

        public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
            let storage = view[\.storage].value
            switch storage {
            case let .makeView(block):
                return block(inputs)
            case let .makeViewList(block):
                let nodes = block(_ViewListInputs(input: inputs)).outputs.map(\.node)
                let node = LayoutViewContainerNode(
                    layout: AnyLayout(inputs.layout),
                    content: view.value,
                    nodes: nodes
                )
                inputs.registerNodeForStorages(node)
                return _ViewOutputs(node: node)
            }
        }
    }

    /// A view that describes the effect of pressing the button.
    public let label: Label

    /// The state of the button style.
    public let state: Button.State

    /// A Boolean value indicating whether the control is in the selected state.
    public var isSelected: Bool {
        state.contains(.selected)
    }

    /// A Boolean value indicating whether the control is in the selected state.
    /// Alias to isSelected property
    public var isPressed: Bool { self.isSelected }

    /// A Boolean value indicating whether the control draws a highlight.
    public var isHighlighted: Bool {
        state.contains(.highlighted)
    }
}

extension View {
    /// Sets the style for buttons within this view to a button style with a custom appearance and standard interaction behavior.
    ///
    /// - Parameter style: The button style to apply.
    /// - Returns: The view with the button style applied.
    public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View {
        self.environment(\.buttonStyle, style)
    }
}

/// The default button style, based on the button’s context.
public struct DefaultButtonStyle: ButtonStyle {
    /// Initialize a new default button style.
    public init() {}

    /// Make the body of the default button style.
    ///
    /// - Parameter configuration: The configuration of the default button style.
    /// - Returns: The body of the default button style.
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// The default button style used inside navigation bars.
public struct NavigationBarButtonStyle: ButtonStyle {
    private enum Constants {
        static let height: Float = 48
        static let horizontalPadding: Float = 12
    }

    /// Initialize a new navigation bar button style.
    public init() {}

    /// Make the body of the navigation bar button style.
    ///
    /// - Parameter configuration: The configuration of the navigation bar button style.
    /// - Returns: The body of the navigation bar button style.
    public func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isSelected
        let isHoveredOrFocused = configuration.isHighlighted || configuration.state.contains(.focused)
        let glass = isPressed ? Glass.interaction : (isHoveredOrFocused ? Glass.regular : Glass.regular)

        return configuration.label
            .padding(.horizontal, Constants.horizontalPadding)
            .frame(minWidth: Constants.height, minHeight: Constants.height)
            .glassEffect(glass, in: .capsule)
            .animation(.linear(duration: 0.2), value: isPressed)
    }
}

private enum GlassButtonStyleDefaults {
    static var highlightedGlass: Glass {
        var glass = AdaColorPalette.landingButtonGlass
        glass.glassTintStrength = 0.92
        glass.glareIntensity = 0.62
        glass.tintColor = Color(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18)
        return glass
    }
}

/// A liquid glass button style for prominent Ada UI controls.
///
/// Styles are copied through Sendable environment/modifier storage, but all
/// stateful property-wrapper access is evaluated on the UI actor.
public struct GlassButtonStyle<S: Shape>: ButtonStyle, @unchecked Sendable {
    @Environment(\.isEnabled) private var isEnabled

    public var glass: Glass
    public var highlightedGlass: Glass
    public var pressedGlass: Glass
    public var disabledGlass: Glass
    public var shape: S
    public var foregroundColor: Color
    public var borderColor: Color
    public var borderWidth: Float
    public var horizontalPadding: Float
    public var verticalPadding: Float
    public var minHeight: Float
    public var highlightedScale: Float
    public var pressedScale: Float
    public var disabledOpacity: Float

    /// Initialize a new glass button style.
    public init(
        glass: Glass = AdaColorPalette.landingButtonGlass,
        highlightedGlass: Glass? = nil,
        pressedGlass: Glass = .interaction,
        disabledGlass: Glass = .clear,
        shape: S,
        foregroundColor: Color = .white,
        borderColor: Color = AdaColorPalette.landingGlassBorder,
        borderWidth: Float = 1,
        horizontalPadding: Float = 16,
        verticalPadding: Float = 0,
        minHeight: Float = 36,
        highlightedScale: Float = 1.02,
        pressedScale: Float = 1.06,
        disabledOpacity: Float = 0.48
    ) {
        self.glass = glass
        self.highlightedGlass = highlightedGlass ?? GlassButtonStyleDefaults.highlightedGlass
        self.pressedGlass = pressedGlass
        self.disabledGlass = disabledGlass
        self.shape = shape
        self.foregroundColor = foregroundColor
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.minHeight = minHeight
        self.highlightedScale = highlightedScale
        self.pressedScale = pressedScale
        self.disabledOpacity = disabledOpacity
    }

    /// Make the body of the glass button style.
    ///
    /// - Parameter configuration: The configuration of the glass button style.
    /// - Returns: The body of the glass button style.
    public func makeBody(configuration: Configuration) -> some View {
        let controlIsEnabled = isEnabled && configuration.state.isEnabled
        let activeOrFocused = configuration.isHighlighted || configuration.state.contains(.focused)

        return configuration.label
            .foregroundColor(foregroundColor)
            .padding(
                EdgeInsets(
                    top: verticalPadding,
                    leading: horizontalPadding,
                    bottom: verticalPadding,
                    trailing: horizontalPadding
                )
            )
            .frame(minHeight: minHeight)
            .glassEffect(glass(for: configuration, isEnabled: controlIsEnabled, isActiveOrFocused: activeOrFocused), in: shape)
            .overlay {
                shape.stroke(borderColor, lineWidth: borderWidth)
            }
            .scaleEffect(scale(for: configuration, isEnabled: controlIsEnabled, isActiveOrFocused: activeOrFocused))
            .opacity(controlIsEnabled ? 1.0 : disabledOpacity)
            .animation(.linear(duration: 0.2), value: configuration.isPressed)
    }

    private func glass(for configuration: Configuration, isEnabled: Bool, isActiveOrFocused: Bool) -> Glass {
        guard isEnabled else {
            return disabledGlass
        }

        if configuration.isSelected {
            return pressedGlass
        }

        if isActiveOrFocused {
            return highlightedGlass
        }

        return glass
    }

    private func scale(for configuration: Configuration, isEnabled: Bool, isActiveOrFocused: Bool) -> Vector2 {
        guard isEnabled else {
            return .one
        }

        if configuration.isSelected {
            return Vector2(pressedScale)
        }

        if isActiveOrFocused {
            return Vector2(highlightedScale)
        }

        return .one
    }
}

extension GlassButtonStyle where S == CapsuleShape {
    /// Initialize a new capsule-shaped glass button style.
    public init(
        glass: Glass = AdaColorPalette.landingButtonGlass,
        highlightedGlass: Glass? = nil,
        pressedGlass: Glass = .interaction,
        disabledGlass: Glass = .clear,
        foregroundColor: Color = .white,
        borderColor: Color = AdaColorPalette.landingGlassBorder,
        borderWidth: Float = 1,
        horizontalPadding: Float = 16,
        verticalPadding: Float = 0,
        minHeight: Float = 36,
        highlightedScale: Float = 1.02,
        pressedScale: Float = 1.06,
        disabledOpacity: Float = 0.48
    ) {
        self.init(
            glass: glass,
            highlightedGlass: highlightedGlass,
            pressedGlass: pressedGlass,
            disabledGlass: disabledGlass,
            shape: CapsuleShape(),
            foregroundColor: foregroundColor,
            borderColor: borderColor,
            borderWidth: borderWidth,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            minHeight: minHeight,
            highlightedScale: highlightedScale,
            pressedScale: pressedScale,
            disabledOpacity: disabledOpacity
        )
    }
}

extension ButtonStyle where Self == GlassButtonStyle<CapsuleShape> {
    /// The default capsule-shaped liquid glass button style.
    public static var glass: GlassButtonStyle<CapsuleShape> {
        GlassButtonStyle()
    }
}

struct ButtonEnvironmentKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any ButtonStyle = DefaultButtonStyle()
}

extension EnvironmentValues {
    var buttonStyle: any ButtonStyle {
        get { return self[ButtonEnvironmentKey.self] }
        set { self[ButtonEnvironmentKey.self] = newValue }
    }
}

/// A type-erased button style.
public struct AnyButtonStyle: ButtonStyle {
    /// The style of the type-erased button style.
    let style: any ButtonStyle

    /// Initialize a new type-erased button style.
    ///
    /// - Parameter style: The style to erase.
    public init<S: ButtonStyle>(erasing style: S) {
        self.style = style
    }

    /// Make the body of the type-erased button style.
    ///
    /// - Parameter configuration: The configuration of the type-erased button style.
    /// - Returns: The body of the type-erased button style.
    public func makeBody(configuration: Configuration) -> AnyView {
        AnyView(style.makeBody(configuration: configuration))
    }
}
