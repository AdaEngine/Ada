@_spi(Internal) @testable import AdaApp
import AdaECS
@testable import AdaPhysics
import AdaTransform
import Math
import Testing

@MainActor
@Suite(.serialized)
struct CharacterCurb3DTests {
    @Test func aLowCurbDoesNotPreventJumpingFromTheFloor() async throws {
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics3DPlugin()).addPlugin(TransformPlugin())
        try await app.build()
        let vertices: [Vector3] = [
            [-5, 0, -5], [5, 0, -5], [5, 0, 5], [-5, 0, 5],
            [0.8, 0, -5], [1.1, 0, -5], [1.1, 0, 5], [0.8, 0, 5],
            [0.8, 0.26, -5], [1.1, 0.26, -5], [1.1, 0.26, 5], [0.8, 0.26, 5],
        ]
        let indices: [UInt32] = [
            0, 2, 1, 0, 3, 2,
            8, 10, 9, 8, 11, 10, 4, 7, 11, 4, 11, 8,
            5, 9, 10, 5, 10, 6, 4, 8, 9, 4, 9, 5,
            7, 6, 10, 7, 10, 11, 4, 5, 6, 4, 6, 7,
        ]
        let shape = try Shape3DResource.generateTriangleMesh(vertices: vertices, indices: indices)
        app.main.spawn { PhysicsBody3DComponent(shapes: [shape], mode: .static); Transform() }
        var controller = CharacterController3DComponent(radius: 0.32, height: 1.8)
        controller.desiredVelocity = [3.5, 0, 0]
        let player = app.main.spawn { controller; Transform(position: [0, 0.2, 0]) }
        await app.main.runScheduler(.physicsSync)
        app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        for _ in 0..<120 {
            await app.main.runScheduler(.physicsStep)
            await app.main.runScheduler(.physicsWriteback)
            await app.main.runScheduler(.postUpdate)
        }
        controller = try #require(player.components[CharacterController3DComponent.self])
        #expect(controller.isGrounded, "The curb contact must not discard floor support.")
        let before = try #require(player.components[Transform.self]).position
        controller.jumpRequested = true
        player.components[CharacterController3DComponent.self] = controller
        for _ in 0..<12 {
            await app.main.runScheduler(.physicsStep)
            await app.main.runScheduler(.physicsWriteback)
            await app.main.runScheduler(.postUpdate)
        }
        #expect(try #require(player.components[Transform.self]).position.y > before.y + 0.5)
    }
}
