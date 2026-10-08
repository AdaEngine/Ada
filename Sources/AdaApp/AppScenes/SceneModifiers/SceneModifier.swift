//
//  SceneModifier.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/9/23.
//

public struct _ModifiedScene<Content: SceneModifier>: AppScene {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    enum Storage {
        case makeScene((_SceneInputs) -> _SceneOutputs)
    }

    let storage: Storage

    public static func _makeView(_ view: _AppSceneNode<Self>, inputs: _SceneInputs) -> _SceneOutputs {
        let storage = view[\.storage].value
        switch storage {
        case let .makeScene(block):
            return block(inputs)
        }
    }
}
