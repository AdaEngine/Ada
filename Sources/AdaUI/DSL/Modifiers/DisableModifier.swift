//
//  DisableModifier.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 31.07.2024.
//

import AdaUtils

extension View {
    /// Adds a condition that controls whether users can interact with this view.
    public func disabled(_ disabled: Bool) -> some View {
        self.environment(\.isEnabled, !disabled)
    }
}

extension EnvironmentValues {
    /// A Boolean value that indicates whether the view associated with this environment allows user interaction.
    @Entry public var isEnabled: Bool = true
}
