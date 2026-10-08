@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) import AdaEngine
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorSceneSimulationTests {
    @Test("Scene physics runs only in Play", arguments: [false, true])
    func physicsRequiresPlay(isPlaying: Bool) async throws {
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin())
        app.addPlugin(TransformPlugin())
        EditorComponentRegistry.registerBuiltIns()
        EditorSceneViewportView.configureSimulation(in: app, isPlaying: isPlaying)
        app.main.insertResource(FixedTime(deltaTime: 1.0 / 60.0))
        try await app.build()

        let initialPosition = Vector3(0, 10, 0)
        let entity2D = app.main.spawn {
            PhysicsBody2DComponent(shapes: [.generateBox()], mass: 1)
            Transform(position: initialPosition)
        }
        let entity3D = app.main.spawn {
            PhysicsBody3DComponent(shapes: [.generateBox()], mass: 1)
            Transform(position: initialPosition)
        }
        for _ in 0..<60 {
            await app.main.runScheduler(.physicsSync)
            await app.main.runScheduler(.physicsStep)
            await app.main.runScheduler(.physicsWriteback)
        }

        for entity in [entity2D, entity3D] {
            let position = try #require(entity.components[Transform.self]).position
            if isPlaying {
                #expect(position.y < initialPosition.y)
            } else {
                #expect(position == initialPosition)
            }
        }
        #expect((app.main.physicsWorld2D != nil) == isPlaying)
        #expect((app.main.physicsWorld3D != nil) == isPlaying)
    }
}
