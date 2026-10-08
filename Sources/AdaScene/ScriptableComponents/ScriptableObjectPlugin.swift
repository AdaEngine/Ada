//
//  ScriptableObjectPlugin.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 20.12.2025.
//

import AdaApp
import AdaECS

/// Add support for ``ScriptableObject`` and ``ScriptableComponents`` objects for Unity-Like component system.
public struct ScriptableObjectPlugin: Plugin {
    public init() {}

    public func setup(in app: borrowing AppWorlds) {
        ScriptableComponents.registerComponent()

        app
            .addSystem(ScriptComponentUpdateSystem.self, on: .update)
            .addSystem(ScriptUIBindingSystem.self, on: .update)
    }
}
