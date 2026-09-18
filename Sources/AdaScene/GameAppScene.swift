//
//  GameAppScene.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/14/22.
//

import AdaApp
import AdaAssets
import AdaECS
import AdaUI
import Math

/// GameAppScene will present game scene in the pre-configured window.
/// You must use this type of scene if your application should launch a game scene.
public struct GameAppScene: AppScene {
    public typealias SceneBlock = @MainActor @Sendable () throws -> Scene

    public var body: some AppScene {
        EmptyWindow()
            .transformAppWorlds { appWorlds in
                do {
                    try unsafe appWorlds.addPlugin(
                        GameScenePlugin(gameScene: AssetHandle<Scene>(gameScene()))
                    )
                } catch {
                    fatalError("\(error)")
                }
            }
    }

    private let gameScene: SceneBlock
    private let filePath: StaticString

    /// Create a new app scene from a game scene.
    public init(
        scene: @escaping SceneBlock,
        filePath: StaticString = #filePath
    ) {
        self.gameScene = scene
        self.filePath = filePath
    }
}

struct GameScenePlugin: Plugin {
    let gameScene: AssetHandle<Scene>

    func setup(in app: AppWorlds) {
        app.main.spawn {
            DynamicScene(scene: gameScene)
        }
    }
}
