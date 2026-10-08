//
//  SearchableModifier.swift
//  AdaEngine
//

import AdaAnimation
import Math

/// The location where a ``View/searchable(text:placement:prompt:)`` search bar is placed.
public enum SearchFieldPlacement: Sendable, Equatable {
    /// Places the search bar above the modified content.
    case top

    /// Places the search bar below the modified content.
    case bottom

    /// Places the search bar over the modified content using the supplied alignment.
    case overlay(alignment: AnchorPoint = .topTrailing)
}

extension View {
    /// Adds an Ada-styled search field to this view.
    ///
    /// This mirrors SwiftUI's `searchable` modifier shape while using AdaUI's layout
    /// primitives. For a standalone control, use ``SearchBar`` directly.
    ///
    /// - Parameters:
    ///   - text: Two-way binding for the search query.
    ///   - placement: Where the search field should be placed relative to this view.
    ///   - prompt: Placeholder shown inside the search field.
    public func searchable(
        text: Binding<String>,
        placement: SearchFieldPlacement = .top,
        prompt: String = "Search"
    ) -> some View {
        self.modifier(
            SearchableModifier(
                text: text,
                placement: placement,
                prompt: prompt
            )
        )
    }
}

private struct SearchableModifier: ViewModifier {
    let text: Binding<String>
    let placement: SearchFieldPlacement
    let prompt: String

    @MainActor
    func body(content: Content) -> some View {
        switch placement {
        case .top:
            VStack(alignment: .leading, spacing: 12) {
                searchBar
                content
            }
        case .bottom:
            VStack(alignment: .leading, spacing: 12) {
                content
                searchBar
            }
        case let .overlay(alignment):
            content.overlay(anchor: alignment) {
                searchBar
                    .padding(12)
            }
        }
    }

    @MainActor
    private var searchBar: some View {
        SearchBar(
            text: text,
            prompt: prompt,
            width: SearchBarDefaults.modifierWidth,
            height: SearchBarDefaults.height
        )
    }
}
