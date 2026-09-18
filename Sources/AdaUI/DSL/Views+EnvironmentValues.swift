//
//  EnvironmentValues.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 24.06.2024.
//

import AdaApp
import AdaText
import AdaUtils

extension EnvironmentValues {
    /// The default font of this environment.
    @Entry public var font: Font?

    /// The default foreground color of this environment.
    @Entry public var foregroundColor: Color?

    /// Current scale factor of the screen.
    @Entry public var scaleFactor: Float = Screen.main?.scale ?? 1

    /// The maximum number of lines that text can occupy in a view.
    @Entry public var lineLimit: Int?

    /// The line break mode that text uses when it reaches the available width.
    @Entry public var lineBreakMode: LineBreakMode = .byWordWrapping

    /// The alignment of wrapped text lines.
    @Entry public var multilineTextAlignment: TextAlignment = .leading

    /// The direction in which horizontal layout and text flow.
    @Entry public var layoutDirection: LayoutDirection = .leftToRight

    /// Returns accent color of the system.
    /// `Color.accentColor` is process-global platform state updated during app startup.
    @Entry public var accentColor: Color = unsafe Color.accentColor

    /// The safe area insets of the nearest container or screen.
    @Entry public var safeAreaInsets: EdgeInsets = EdgeInsets()

    /// Insets reserved by platform window chrome that overlays app content.
    @Entry internal var navigationBarChromeInsets: EdgeInsets = EdgeInsets()
}

extension View {
    /// Apply accent color to all child views.
    public func accentColor(_ color: Color) -> some View {
        self.environment(\.accentColor, color)
    }
}
