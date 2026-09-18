//
//  VisibilityPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/6/23.
//

import AdaApp
import AdaECS

/// Visibility Plugin turn on a frustum culling for all entities on the screen.
public struct VisibilityPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        app.addSystem(VisibilitySystem.self, on: .preUpdate)
    }
}
