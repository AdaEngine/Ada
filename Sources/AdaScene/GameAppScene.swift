//
//  GameAppScene.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/14/22.
//

import AdaApp
import AdaECS
import AdaUI

/// GameAppScene will present game scene in the pre-configured window.
/// You must use this type of scene if your application should launch a game scene.
public struct GameAppScene: AppScene {
    public typealias SceneBlock = @MainActor @Sendable () throws -> Scene

    public var body: some AppScene {
        EmptyWindow()
            .transformAppWorlds { appWorlds in
                do {
                    try appWorlds.addPlugin(
                        GameScenePlugin(gameScene: gameScene(), make: gameScene)
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
    let gameScene: Scene
    let make: GameAppScene.SceneBlock

    func setup(in app: AppWorlds) {
        let navigator = app.main.getResource(SceneNavigator.self) ?? SceneNavigator(world: app.main)
        if app.main.getResource(SceneNavigator.self) == nil {
            app.main.insertResource(navigator)
            app.main.addSystem(SceneNavigationSystem.self, on: .postUpdate)
        }
        navigator.installInitialScene(gameScene, make: make)
    }
}
