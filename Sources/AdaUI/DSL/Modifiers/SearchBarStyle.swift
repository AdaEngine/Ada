//
//  SearchBarStyle.swift
//  AdaEngine
//

import AdaText
import AdaUtils

/// A protocol that defines a search bar style.
@_typeEraser(AnySearchBarStyle)
@MainActor public protocol SearchBarStyle: Sendable {
    /// The body of the search bar style.
    associatedtype Body: View

    /// The configuration of the search bar style.
    typealias Configuration = SearchBarStyleConfiguration

    /// Make the body of the search bar style.
    ///
    /// - Parameter configuration: The configuration of the search bar style.
    /// - Returns: The body of the search bar style.
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// The properties of a search bar.
public struct SearchBarStyleConfiguration {
    /// A view that describes the text input part of the search bar.
    public struct Label: View {
        public typealias Body = Never
        public var body: Never { fatalError("Unreachable code") }

        enum Storage {
            case makeView((_ViewInputs) -> _ViewOutputs)
            case makeViewList((_ViewListInputs) -> _ViewListOutputs)
        }

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

    /// The text input label configured by ``SearchBar``.
    public let label: Label

    /// An action that removes the entire search query.
    public let clear: () -> Void

    /// Whether the search query is currently empty.
    public let isEmpty: Bool

    /// Initialize a new search bar style configuration.
    ///
    /// - Parameters:
    ///   - label: The text input label configured by ``SearchBar``.
    ///   - clear: An action that removes the entire search query.
    ///   - isEmpty: Whether the search query is currently empty.
    public init(label: Label, clear: @escaping () -> Void, isEmpty: Bool) {
        self.label = label
        self.clear = clear
        self.isEmpty = isEmpty
    }
}

extension View {
    /// Sets the style for search bars within this view.
    ///
    /// - Parameter style: The search bar style to apply.
    /// - Returns: The view with the search bar style applied.
    public func searchBarStyle<S: SearchBarStyle>(_ style: S) -> some View {
        self.environment(\.searchBarStyle, style)
    }
}

/// The default search bar style with Ada's glass effect.
public struct DefaultSearchBarStyle: SearchBarStyle {
    /// Initialize a new default search bar style.
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("⌕")
                .font(.system(size: 15))
                .foregroundColor(AdaColorPalette.muted)

            configuration.label

            if !configuration.isEmpty {
                Button(action: configuration.clear) {
                    Text("×")
                        .font(.system(size: 15))
                        .foregroundColor(AdaColorPalette.muted)
                }
                .accessibilityIdentifier("AdaUI.SearchBar.clearButton")
                .buttonStyle(SearchBarClearButtonStyle())
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .glassEffect(AdaColorPalette.searchCapsuleGlass, in: CapsuleShape())
    }
}

/// A plain search bar style with rectangular borders.
public struct PlainSearchBarStyle: SearchBarStyle {
    /// Initialize a new plain search bar style.
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.label

            if !configuration.isEmpty {
                Button(action: configuration.clear) {
                    Text("×")
                        .font(.system(size: 15))
                        .foregroundColor(AdaColorPalette.muted)
                }
                .accessibilityIdentifier("AdaUI.SearchBar.clearButton")
                .buttonStyle(SearchBarClearButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .background {
            RectangleShape().fill(AdaColorPalette.searchCapsuleSurface)
        }
        .overlay {
            RectangleShape().stroke(AdaColorPalette.searchCapsuleBorder, lineWidth: 1)
        }
    }
}

struct SearchBarEnvironmentKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any SearchBarStyle = DefaultSearchBarStyle()
}

extension EnvironmentValues {
    public var searchBarStyle: any SearchBarStyle {
        get { self[SearchBarEnvironmentKey.self] }
        set { self[SearchBarEnvironmentKey.self] = newValue }
    }
}

/// A type-erased search bar style.
public struct AnySearchBarStyle: SearchBarStyle {
    /// The style of the type-erased search bar style.
    let style: any SearchBarStyle

    /// Initialize a new type-erased search bar style.
    ///
    /// - Parameter style: The style to erase.
    public init<S: SearchBarStyle>(erasing style: S) {
        self.style = style
    }

    /// Make the body of the type-erased search bar style.
    ///
    /// - Parameter configuration: The configuration of the type-erased search bar style.
    /// - Returns: The body of the type-erased search bar style.
    public func makeBody(configuration: Configuration) -> AnyView {
        AnyView(style.makeBody(configuration: configuration))
    }
}

private struct SearchBarClearButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 24, height: 24)
            .background {
                CircleShape().fill(configuration.state.isHighlighted ? AdaColorPalette.footerButtonHighlighted : .clear)
            }
            .opacity(configuration.state.isHighlighted ? 0.72 : 1.0)
    }
}
