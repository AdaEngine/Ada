//
//  ToggleStyle.swift
//  AdaEngine
//

/// A type that defines the appearance of a toggle.
@_typeEraser(AnyToggleStyle)
@MainActor public protocol ToggleStyle: Sendable {
    associatedtype Body: View
    typealias Configuration = ToggleStyleConfiguration

    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// The label and value supplied to a toggle style.
public struct ToggleStyleConfiguration {
    /// The value controlled by the toggle. Set it to respond to an interaction.
    public let isOn: Binding<Bool>
    /// The toggle's descriptive label.
    public let label: AnyView
    /// Whether the label should be visible.
    public let showsLabel: Bool

    public init(isOn: Binding<Bool>, label: AnyView, showsLabel: Bool = true) {
        self.isOn = isOn
        self.label = label
        self.showsLabel = showsLabel
    }
}

extension View {
    /// Sets the appearance of toggles in this view.
    public func toggleStyle<S: ToggleStyle>(_ style: S) -> some View {
        environment(\.toggleStyle, style)
    }

    /// Hides descriptive toggle labels while retaining their controls.
    public func labelsHidden() -> some View {
        environment(\.toggleLabelsHidden, true)
    }
}

/// A switch-style toggle with configurable colors, text, and row decoration.
public struct SwitchToggleStyle: ToggleStyle {
    public var tint: Color
    public var offTint: Color
    public var thumbColor: Color
    public var labelColor: Color?
    public var statusColor: Color?
    public var rowBackground: Color?
    public var rowBorder: Color?
    public var showsStateText: Bool
    public var onText: String
    public var offText: String
    public var rowCornerRadius: Float
    public var rowHeight: Float
    public var horizontalPadding: Float

    /// Creates a switch style. Omit row colors for a plain switch.
    public init(
        tint: Color = .blue,
        offTint: Color = .gray,
        thumbColor: Color = .white,
        labelColor: Color? = nil,
        statusColor: Color? = nil,
        rowBackground: Color? = nil,
        rowBorder: Color? = nil,
        showsStateText: Bool = false,
        onText: String = "On",
        offText: String = "Off",
        rowCornerRadius: Float = 7,
        rowHeight: Float = 32,
        horizontalPadding: Float = 0
    ) {
        self.tint = tint
        self.offTint = offTint
        self.thumbColor = thumbColor
        self.labelColor = labelColor
        self.statusColor = statusColor
        self.rowBackground = rowBackground
        self.rowBorder = rowBorder
        self.showsStateText = showsStateText
        self.onText = onText
        self.offText = offText
        self.rowCornerRadius = rowCornerRadius
        self.rowHeight = rowHeight
        self.horizontalPadding = horizontalPadding
    }

    public func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.wrappedValue.toggle() }) {
            HStack(spacing: 12) {
                if configuration.showsLabel {
                    configuration.label
                        .font(.system(size: 13))
                    Spacer()
                }
                if showsStateText {
                    Text(configuration.isOn.wrappedValue ? onText : offText)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor ?? labelColor ?? .gray)
                }
                ZStack(anchor: .leading) {
                    RoundedRectangleShape(cornerRadius: 10)
                        .fill(configuration.isOn.wrappedValue ? tint : offTint)
                        .frame(width: 36, height: 20)
                    CircleShape().fill(thumbColor)
                        .frame(width: 16, height: 16)
                        .offset(x: configuration.isOn.wrappedValue ? 18 : 2)
                }
                .frame(width: 36, height: 20)
            }
            .foregroundColor(labelColor ?? .white)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: 0, maxWidth: configuration.showsLabel ? .infinity : nil, minHeight: rowHeight)
            .background(RoundedRectangleShape(cornerRadius: rowCornerRadius).fill(rowBackground ?? .clear))
            .overlay {
                RoundedRectangleShape(cornerRadius: rowCornerRadius).stroke(rowBorder ?? .clear, lineWidth: 1)
            }
        }
        .buttonStyle(DefaultButtonStyle())
    }
}

extension ToggleStyle where Self == SwitchToggleStyle {
    /// The default switch appearance.
    public static var `switch`: SwitchToggleStyle { SwitchToggleStyle() }
}

struct ToggleStyleEnvironmentKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any ToggleStyle = SwitchToggleStyle()
}

struct ToggleLabelsHiddenEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var toggleStyle: any ToggleStyle {
        get { self[ToggleStyleEnvironmentKey.self] }
        set { self[ToggleStyleEnvironmentKey.self] = newValue }
    }

    var toggleLabelsHidden: Bool {
        get { self[ToggleLabelsHiddenEnvironmentKey.self] }
        set { self[ToggleLabelsHiddenEnvironmentKey.self] = newValue }
    }
}

/// A type-erased toggle style.
public struct AnyToggleStyle: ToggleStyle {
    let style: any ToggleStyle

    public init<S: ToggleStyle>(erasing style: S) {
        self.style = style
    }

    public func makeBody(configuration: Configuration) -> AnyView {
        AnyView(style.makeBody(configuration: configuration))
    }
}
