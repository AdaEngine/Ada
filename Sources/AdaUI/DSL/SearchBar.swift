//
//  SearchBar.swift
//  AdaEngine
//

import AdaText
import AdaUtils

/// A reusable search input view with Ada's default search styling.
///
/// Use `SearchBar` when you need a standalone search control in your layout.
/// Use ``View/searchable(text:placement:prompt:)`` when you want to attach the
/// search control to an existing view in a SwiftUI-like way.
public struct SearchBar: View {
    public var text: Binding<String>
    public var prompt: String
    public var width: Float?
    public var height: Float

    /// Creates a search bar.
    ///
    /// - Parameters:
    ///   - text: Two-way binding for the search query.
    ///   - prompt: Placeholder shown when the query is empty.
    ///   - width: Optional fixed width. `nil` lets the parent layout propose the width.
    ///   - height: Fixed control height.
    public init(
        text: Binding<String>,
        prompt: String = "Search",
        width: Float? = nil,
        height: Float = SearchBarDefaults.height
    ) {
        self.text = text
        self.prompt = prompt
        self.width = width
        self.height = height
    }

    public var body: some View {
        SearchBarStyledContent(
            text: text,
            prompt: prompt,
            width: width,
            height: height
        )
    }
}

private struct SearchBarStyledContent: View {
    @Environment(\.searchBarStyle) private var style
    @Environment(\.foregroundColor) private var foreground

    let text: Binding<String>
    let prompt: String
    let width: Float?
    let height: Float

    var body: some View {
        let configuration = SearchBarStyleConfiguration(
            label: SearchBarStyleConfiguration.Label(
                storage: .makeView({ inputs in
                    let view = AnyView(
                        TextField(prompt, text: text)
                            .font(.system(size: 13))
                            .foregroundColor(foreground ?? .white)
                            .textFieldStyle(PlainTextFieldStyle())
                            .environment(\._isTextFieldPrimitive, false)
                    )
                    return AnyView._makeView(_ViewGraphNode(value: view), inputs: inputs)
                })
            ),
            clear: {
                text.wrappedValue = ""
            },
            isEmpty: text.wrappedValue.isEmpty
        )

        return AnyView(style.makeBody(configuration: configuration))
            .frame(width: width, height: height)
    }
}

/// Default sizing for Ada search controls.
public enum SearchBarDefaults {
    public static let height: Float = 32
    public static let modifierWidth: Float = 280
}
