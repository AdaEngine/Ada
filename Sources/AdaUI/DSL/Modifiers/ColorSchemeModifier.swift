//
//  ColorSchemeModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 29.07.2024.
//

import AdaUtils

/// The possible color schemes, corresponding to the light and dark appearances.
public enum ColorScheme: Hashable, Sendable, CaseIterable {
    case light
    case dark
}

extension View {
    /// Sets the preferred color scheme for this presentation.
    public func preferredColorScheme(_ scheme: ColorScheme) -> some View {
        self.environment(\.colorScheme, scheme)
    }
}

extension EnvironmentValues {
    @Entry public var colorScheme: ColorScheme = .light
}
