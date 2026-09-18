//
//  TransformPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/5/24.
//

import AdaApp
import AdaECS
import Math

/// Add support for ``Transform`` and ``GlobalTransform`` components.
public struct TransformPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        Transform.registerComponent()
        GlobalTransform.registerComponent()

        app
            .addSystem(TransformSystem.self, on: .postUpdate)
            .addSystem(ChildTransformSystem.self, on: .postUpdate)
    }
}
