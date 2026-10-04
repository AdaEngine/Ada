@_spi(Internal) @testable import AdaApp
import AdaECS
@testable import AdaPhysics
import AdaTransform
import Math
import Testing

@MainActor
@Suite(.serialized)
struct CharacterController3DTests {
    let app: AppWorlds

    init() async throws {
        app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics3DPlugin()).addPlugin(TransformPlugin())
        try await app.build()
    }

    @Test
    func fallsOntoFloorAndRemainsGroundedWhileIdle() async throws {
        box(size: [20, 1, 20], position: [0, -0.5, 0])
        let character = spawn(at: [0, 3, 0])
        await step(120)
        let transform = try #require(character.components[Transform.self])
        let controller = try #require(character.components[CharacterController3DComponent.self])
        #expect(abs(transform.position.y) < 0.02)
        #expect(controller.isGrounded)
        #expect(abs(controller.velocity.y) < 0.02)
        #expect(transform.scale == Vector3(0.5, 0.5, 0.5))
        #expect(abs(try #require(character.components[GlobalTransform.self]).getTransform().position.y) < 0.02)
    }

    @Test
    func slidesAlongWallAndStopsInsteadOfPenetrating() async throws {
        box(size: [20, 1, 20], position: [0, -0.5, 0])
        box(size: [0.2, 4, 20], position: [1, 2, 0])
        let character = spawn(at: .zero, velocity: [2, 0, 2])
        await step(90)
        let position = try #require(character.components[Transform.self]).position
        let state = try #require(character.components[CharacterController3DComponent.self])
        #expect(position.x < 0.53)
        #expect(position.x > 0.45)
        #expect(position.z > 2.5)
        #expect(state.isGrounded)
        #expect(abs(state.velocity.x) < 0.05)
        #expect(state.velocity.z > 1.9)
    }

    @Test
    func sweptCapsuleDoesNotTunnelThroughThinWall() async throws {
        box(size: [0.02, 4, 10], position: [1, 2, 0])
        app.main.physicsWorld3D?.gravity = .zero
        let character = spawn(at: .zero, velocity: [500, 0, 0])
        await step(1)
        let position = try #require(character.components[Transform.self]).position
        #expect(position.x < 0.62)
        #expect(position.x > 0.55)
        #expect(abs(position.z) < 0.001)
    }

    @Test
    func jumpIsConsumedOnceAndLandsAfterCeilingContact() async throws {
        box(size: [20, 1, 20], position: [0, -0.5, 0])
        box(size: [4, 0.2, 4], position: [0, 2.4, 0])
        let character = spawn(at: .zero)
        await step(2)
        var state = try #require(character.components[CharacterController3DComponent.self])
        #expect(state.isGrounded)
        state.jumpRequested = true
        character.components[CharacterController3DComponent.self] = state
        await step(1)
        state = try #require(character.components[CharacterController3DComponent.self])
        #expect(!state.jumpRequested)
        #expect(!state.isGrounded)
        #expect(state.velocity.y > 0)
        var maximumY: Float = 0
        for _ in 0..<120 {
            await step(1)
            maximumY = max(maximumY, try #require(character.components[Transform.self]).position.y)
        }
        #expect(maximumY > 0.3)
        #expect(maximumY < 0.53)
        #expect(try #require(character.components[CharacterController3DComponent.self]).isGrounded)
        #expect(abs(try #require(character.components[Transform.self]).position.y) < 0.02)
    }

    @Test
    func sensorsDoNotBlockOrGroundCharacter() async throws {
        box(size: [1, 4, 10], position: [1, 2, 0], trigger: true)
        box(size: [20, 1, 20], position: [0, -0.5, 0], trigger: true)
        let character = spawn(at: .zero, velocity: [2, 0, 0])
        await step(60)
        let position = try #require(character.components[Transform.self]).position
        #expect(position.x > 1.9)
        #expect(position.y < -4)
        #expect(!(try #require(character.components[CharacterController3DComponent.self])).isGrounded)
    }

    @Test
    func sphereAndRotatedBoxParticipateInSceneCollision() async throws {
        app.main.physicsWorld3D?.gravity = .zero
        app.main.spawn {
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.5)], mode: .static)
            Transform(position: [2, 0.5, 0])
        }
        let character = spawn(at: .zero, velocity: [2, 0, 0])
        await step(120)
        #expect(try #require(character.components[Transform.self]).position.x < 1.2)
        box(size: [0.2, 4, 8], position: [0, 2, 4], rotation: Quat(axis: .up, angle: .pi / 4))
        character.components[Transform.self] = Transform(position: [1, 0, 3])
        var state = CharacterController3DComponent()
        state.desiredVelocity = [-4, 0, 4]
        state.acceleration = 100_000
        character.components[CharacterController3DComponent.self] = state
        await step(60)
        let position = try #require(character.components[Transform.self]).position
        // The plane x - z = -4 must remain on the approach side, with capsule clearance.
        #expect(position.x - position.z > -3.5)
        #expect(position.x - position.z < -3.1)
    }

    @Test
    func restingCapsuleRecoversFromOverlapAndCornerContacts() async throws {
        app.main.physicsWorld3D?.gravity = .zero
        box(size: [2, 4, 2], position: [0, 2, 0])
        let character = spawn(at: [1.3, 0, 0])
        await step(2)
        #expect(try #require(character.components[Transform.self]).position.x > 1.38)
        box(size: [0.2, 4, 20], position: [3, 2, 0])
        box(size: [20, 4, 0.2], position: [0, 2, 3])
        character.components[Transform.self] = Transform(position: [2, 0, 2])
        var state = CharacterController3DComponent()
        state.desiredVelocity = [4, 0, 4]
        state.acceleration = 100_000
        character.components[CharacterController3DComponent.self] = state
        await step(90)
        let position = try #require(character.components[Transform.self]).position
        #expect(position.x > 2.45 && position.x < 2.53)
        #expect(position.z > 2.45 && position.z < 2.53)
        #expect(try #require(character.components[CharacterController3DComponent.self]).velocity.length < 0.02)
    }

    @Test
    func accelerationBrakingAndInvalidInputKeepFiniteState() async throws {
        app.main.physicsWorld3D?.gravity = .zero
        let character = spawn(at: .zero)
        var state = CharacterController3DComponent()
        state.acceleration = 6
        state.deceleration = 12
        state.desiredVelocity = [2, 0, 0]
        character.components[CharacterController3DComponent.self] = state
        await step(1)
        #expect(abs(try #require(character.components[CharacterController3DComponent.self]).velocity.x - 0.1) < 0.001)
        await step(30)
        state = try #require(character.components[CharacterController3DComponent.self])
        #expect(abs(state.velocity.x - 2) < 0.001)
        state.desiredVelocity = .zero
        character.components[CharacterController3DComponent.self] = state
        await step(11)
        #expect(try #require(character.components[CharacterController3DComponent.self]).velocity == .zero)
        var position = Vector3.zero
        state.desiredVelocity.x = .nan
        let physics = try #require(app.main.physicsWorld3D)
        physics.moveCharacter(&state, position: &position, deltaTime: 1 / 60)
        #expect(position == .zero)
        physics.moveCharacter(&state, position: &position, deltaTime: .infinity)
        #expect(position == .zero)
        #expect(CharacterController3DComponent(radius: .nan, height: -1).height == 0.8)
    }

    private func spawn(at position: Vector3, velocity: Vector3 = .zero) -> Entity {
        var controller = CharacterController3DComponent()
        controller.desiredVelocity = velocity
        controller.acceleration = 100_000
        return app.main.spawn {
            controller
            Transform(scale: [0.5, 0.5, 0.5], position: position)
        }
    }

    @discardableResult
    private func box(size: Vector3, position: Vector3, trigger: Bool = false, rotation: Quat = .identity) -> Entity {
        app.main.spawn {
            PhysicsBody3DComponent(shapes: [.generateBox(width: size.x, height: size.y, depth: size.z)], mode: .static, isTrigger: trigger)
            Transform(rotation: rotation, position: position)
        }
    }

    private func step(_ count: Int) async {
        await app.main.runScheduler(.physicsSync)
        app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        for _ in 0..<count {
            await app.main.runScheduler(.physicsStep)
            await app.main.runScheduler(.physicsWriteback)
            await app.main.runScheduler(.postUpdate)
        }
    }
}
