import AdaRender
import AdaUtils

/// A nine-slice button skin. Missing state images fall back to the normal image.
public struct TextureButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public var normal: Image
    public var highlighted: Image?
    public var pressed: Image?
    public var disabled: Image?
    public var capInsets: ImageCapInsets
    public var selectionEffect: Bool
    public var selectionColor: Color

    public init(
        normal: Image,
        highlighted: Image? = nil,
        pressed: Image? = nil,
        disabled: Image? = nil,
        capInsets: ImageCapInsets = .init(0),
        selectionEffect: Bool = false,
        selectionColor: Color = Color(1, 0.88, 0.54, 1)
    ) {
        self.normal = normal
        self.highlighted = highlighted
        self.pressed = pressed
        self.disabled = disabled
        self.capInsets = capInsets
        self.selectionEffect = selectionEffect
        self.selectionColor = selectionColor
    }

    func image(for state: Button.State) -> Image {
        if state.contains(.disabled) {
            return disabled ?? normal
        }
        if state.contains(.selected) {
            return pressed ?? normal
        }
        if state.contains(.highlighted) || state.contains(.focused) {
            return highlighted ?? normal
        }
        return normal
    }

    public func makeBody(configuration: Configuration) -> some View {
        let enabled = isEnabled && configuration.state.isEnabled
        let selected = selectionEffect && enabled && (configuration.isHighlighted || configuration.isPressed || configuration.state.contains(.focused))
        return configuration.label
            .background {
                image(for: enabled ? configuration.state : .disabled).resizable(capInsets: capInsets)
            }
            .overlay {
                RoundedRectangleShape(cornerRadius: 6)
                    .stroke(selectionColor.opacity(selected ? 0.22 : 0), lineWidth: 8)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangleShape(cornerRadius: 6)
                    .stroke(selectionColor.opacity(selected ? 1 : 0), lineWidth: configuration.isPressed ? 3 : 2)
                    .allowsHitTesting(false)
            }
    }
}
