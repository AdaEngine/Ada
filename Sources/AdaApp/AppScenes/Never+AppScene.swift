//
//  Never+AppScene.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/14/22.
//

extension Never: AppScene {
    public var body: Never { fatalError("Never has no body") }

    @MainActor @preconcurrency
    public static func _makeView(
        _: _AppSceneNode<Never>,
        inputs: _SceneInputs
    ) -> _SceneOutputs {
        // For Never, just forward inputs as outputs as per default behavior.
        _SceneOutputs(appWorlds: inputs.appWorlds)
    }
}
