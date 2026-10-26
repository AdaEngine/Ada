@_spi(Internal) @testable import AdaApp
import AdaECS
@testable import AdaPhysics
import AdaTransform
import Foundation
import Math
import Testing

@MainActor
@Suite(.serialized)
struct CharacterController3DResizeTests {
    let app: AppWorlds

    init() async throws {
        app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics3DPlugin()).addPlugin(TransformPlugin())
        try await app.build()
        app.main.physicsWorld3D?.gravity = .zero
    }

    @Test(arguments: [false, true])
    func thinTriangleCeilingThroughTheAxisRefusesGrowth(sensor: Bool) async throws {
        box(size: [20, 1, 20], at: [0, -0.5, 0])
        let ceiling = try Shape3DResource.generateTriangleMesh(
            vertices: [[-2, 1.4, -2], [-2, 1.4, 2], [2, 1.4, 2], [2, 1.4, -2]], indices: [0, 1, 2, 0, 2, 3]
        )
        app.main.spawn { PhysicsBody3DComponent(shapes: [ceiling], mode: .static, isTrigger: sensor); Transform() }
        let actor = spawn(height: 1)
        await step(3)
        let feet = try #require(actor.components[Transform.self]).position
        try request(2.5, actor)
        await step(1)
        let state = try state(actor)
        #expect(state.height == (sensor ? 2.5 : 1))
        #expect(state.heightChangeBlocked == !sensor)
        #expect((try #require(actor.components[Transform.self]).position - feet).length < 0.001)
    }

    @Test func shrinkingAndStandingPreserveFloorAndSideContacts() async throws {
        box(size: [20, 1, 20], at: [0, -0.5, 0])
        box(size: [0.2, 4, 4], at: [0.5, 2, 0]) // Exact side contact at X=.4.
        let actor = spawn(height: 1.8)
        await step(3)
        let feet = try #require(actor.components[Transform.self]).position
        for height: Float in [1, 0.8, 1.8] {
            try request(height, actor)
            await step(1)
            let current = try state(actor)
            #expect(current.height == height && !current.heightChangeBlocked)
            #expect((try #require(actor.components[Transform.self]).position - feet).length < 0.001)
        }
    }

    @Test func refusedStandingRetriesAfterLeavingAndUsesTheTallSweptShape() async throws {
        box(size: [20, 1, 20], at: [0, -0.5, 0])
        box(size: [2, 0.1, 2], at: [0, 1.45, 0])
        let actor = spawn(height: 1)
        await step(3)
        let feet = try #require(actor.components[Transform.self]).position
        try request(1.8, actor)
        await step(1)
        #expect(try state(actor).height == 1 && state(actor).heightChangeBlocked)
        var moving = try state(actor)
        moving.desiredVelocity = [2, 0, 0]
        moving.acceleration = 100_000
        actor.components[CharacterController3DComponent.self] = moving
        await step(30)
        #expect(try state(actor).height == 1 && state(actor).heightChangeBlocked)
        await step(45)
        #expect(try state(actor).height == 1.8 && !state(actor).heightChangeBlocked)
        moving = try state(actor)
        moving.desiredVelocity = [-50, 0, 0]
        actor.components[CharacterController3DComponent.self] = moving
        await step(6)
        let position = try #require(actor.components[Transform.self]).position
        #expect(position.x > 1.3, "A grown capsule must stop at the roof edge, including a fast return.")
        #expect(abs(position.y - feet.y) < 0.001)
    }

    @Test func shrinkingUnderACeilingHappensBeforeMovement() async throws {
        box(size: [20, 1, 20], at: [0, -0.5, 0])
        box(size: [2, 0.1, 2], at: [0, 1.45, 0])
        let actor = spawn(height: 1.8)
        try request(1, actor)
        await step(1)
        #expect(try state(actor).height == 1 && !state(actor).heightChangeBlocked)
        #expect(try #require(actor.components[Transform.self]).position.length < 0.001)
    }

    @Test func invalidRequestsKeepFiniteGeometryAndFeet() async throws {
        box(size: [20, 1, 20], at: [0, -0.5, 0])
        let actor = spawn(height: 1)
        await step(3)
        let feet = try #require(actor.components[Transform.self]).position
        for height: Float in [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, 0.7] {
            try request(height, actor)
            await step(1)
            #expect(try state(actor).height == 1 && state(actor).heightChangeBlocked)
            #expect(try state(actor).requestedHeight == 1)
            _ = try JSONEncoder().encode(state(actor))
            #expect((try #require(actor.components[Transform.self]).position - feet).length < 0.001)
        }
    }

    @Test func legacyCodingAndReflectionExposeOnlyTheRequestAsWritable() throws {
        let legacy = try JSONDecoder().decode(CharacterController3DComponent.self, from: Data("{\"radius\":0.4,\"height\":1.8}".utf8))
        #expect(legacy.height == 1.8 && legacy.requestedHeight == legacy.height && !legacy.heightChangeBlocked)
        #expect(CharacterController3DComponent(radius: .nan, height: -1).height == 0.8)
        let fields = CharacterController3DComponent.componentDescriptor.fields
        let height = try #require(fields.first { $0.key == "height" })
        let blocked = try #require(fields.first { $0.key == "heightChangeBlocked" })
        let request = try #require(fields.first { $0.key == "requestedHeight" })
        #expect(!height.isWritable && height.write(legacy, .double(9)) == nil)
        #expect(!blocked.isWritable && blocked.read(legacy) == .bool(false) && blocked.write(legacy, .bool(true)) == nil)
        #expect(request.kind == .float && request.isWritable)
        let changed = try #require(request.write(legacy, .double(1.1)) as? CharacterController3DComponent)
        #expect(changed.requestedHeight == 1.1 && changed.height == 1.8)
    }

    @Test func aSavedBlockedStandRequestRetainsItsCrouchedActualHeight() async throws {
        box(size: [20, 1, 20], at: [0, -0.5, 0])
        box(size: [2, 0.1, 2], at: [0, 1.45, 0])
        let actor = spawn(height: 1)
        try request(1.8, actor)
        await step(1)
        try request(.nan, actor) // Reject the bad command while retaining the pending valid stand request.
        let decoded = try JSONDecoder().decode(CharacterController3DComponent.self, from: JSONEncoder().encode(state(actor)))
        #expect(decoded.height == 1 && decoded.requestedHeight == 1.8 && !decoded.heightChangeBlocked)
        actor.components[CharacterController3DComponent.self] = decoded
        await step(1)
        #expect(try state(actor).height == 1 && state(actor).heightChangeBlocked)
        #expect(try #require(actor.components[Transform.self]).position.length < 0.001)
    }

    private func state(_ actor: Entity) throws -> CharacterController3DComponent {
        try #require(actor.components[CharacterController3DComponent.self])
    }

    private func request(_ height: Float, _ actor: Entity) throws {
        var value = try state(actor)
        value.requestedHeight = height
        actor.components[CharacterController3DComponent.self] = value
    }

    private func spawn(height: Float) -> Entity {
        app.main.spawn { CharacterController3DComponent(radius: 0.4, height: height); Transform() }
    }

    @discardableResult
    private func box(size: Vector3, at position: Vector3) -> Entity {
        app.main.spawn {
            PhysicsBody3DComponent(shapes: [.generateBox(width: size.x, height: size.y, depth: size.z)], mode: .static)
            Transform(position: position)
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
