//
//  Theme+Environment.swift
//  AdaEngine
//

import AdaUtils

extension EnvironmentValues {
    /// The current theme available to this view and all of its subviews.
    @Entry public var theme: Theme = Theme()
}

extension View {
    /// Sets the theme for this view and all of its subviews.
    ///
    /// ```swift
    /// ContentView()
    ///     .theme(myTheme)
    /// ```
    public func theme(_ theme: Theme) -> some View {
        self.environment(\.theme, theme)
    }

    /// Transforms the current theme for this view and all of its subviews.
    ///
    /// ```swift
    /// ContentView()
    ///     .transformTheme { theme in
    ///         theme[MyColorsKey.self] = .dark
    ///     }
    /// ```
    public func transformTheme(_ transform: @escaping (inout Theme) -> Void) -> some View {
        self.transformEnvironment(\.theme, transform: transform)
    }
}
