@_spi(Internal) @testable import AdaApp
import AdaECS
@testable import AdaPhysics
import AdaTransform
import box3d
import Math
import Testing

@MainActor
@Suite(.serialized)
struct CharacterController3DStepTests {
    @Test(arguments: [Float(0.08), 0.09, 0.091, 0.10])
    func standingStepIsBoundedByFivePercentOfActualHeight(rise: Float) async throws {
        let fixture = try await Fixture(height: 1.8)
        fixture.box(size: [8, rise, 8], at: [5, rise / 2, 0])
        await fixture.step(3)
        try fixture.move([2, 0, 0])
        await fixture.step(90)
        let position = try fixture.position()
        if rise <= 0.09 {
            #expect(position.x > 2.8 && abs(position.y - rise) < 0.012)
        } else {
            #expect(position.x < 0.8 && abs(position.y) < 0.012, "10 cm exceeds a standing character's 9 cm step.")
            try fixture.move(.zero)
            await fixture.step(20)
            try fixture.move([2, 0, 0])
            await fixture.step(90)
            #expect(try fixture.position().x < 0.8 && abs(fixture.position().y) < 0.012)
        }
        #expect(try fixture.state().isGrounded)
    }

    @Test(arguments: [Float(0.05), 0.055, 0.056, 0.06])
    func crouchedStepUsesResolvedHeight(rise: Float) async throws {
        let fixture = try await Fixture(height: 1.1)
        fixture.box(size: [8, rise, 8], at: [5, rise / 2, 0])
        fixture.box(size: [30, 0.1, 30], at: [0, 1.55, 0])
        var pending = try fixture.state()
        pending.requestedHeight = 1.8
        fixture.actor.components[CharacterController3DComponent.self] = pending
        await fixture.step(3)
        try fixture.move([2, 0, 0])
        await fixture.step(90)
        let position = try fixture.position()
        #expect(try fixture.state().height == 1.1 && fixture.state().heightChangeBlocked)
        if rise <= 0.055 {
            #expect(position.x > 2.8 && abs(position.y - rise) < 0.012)
        } else {
            #expect(position.x < 0.85 && abs(position.y) < 0.012, "6 cm exceeds a crouched character's 5.5 cm step.")
            try fixture.move(.zero)
            await fixture.step(20)
            try fixture.move([2, 0, 0])
            await fixture.step(90)
            #expect(try fixture.position().x < 0.85 && abs(fixture.position().y) < 0.012)
        }
    }

    @Test func continuousWalkableSlopeIsNotLimitedToOneStepHeight() async throws {
        let fixture = try await Fixture(height: 1.8)
        let ramp = try Shape3DResource.generateTriangleMesh(
            vertices: [[0.5, 0, -2], [4.5, 1, -2], [4.5, 1, 2], [0.5, 0, 2]], indices: [0, 2, 1, 0, 3, 2]
        )
        fixture.app.main.spawn { PhysicsBody3DComponent(shapes: [ramp], mode: .static); Transform() }
        await fixture.step(3)
        try fixture.move([2, 0, 0])
        await fixture.step(90)
        #expect(try fixture.position().x > 2.7 && fixture.position().y > 0.5)
        #expect(try fixture.state().isGrounded)
    }

    @Test(arguments: [false, true])
    func thinOverheadTriangleBlocksTheWholeUpwardPathUnlessItIsASensor(sensor: Bool) async throws {
        let fixture = try await Fixture(height: 1.8)
        fixture.box(size: [8, 0.08, 8], at: [5, 0.04, 0])
        let ceiling = try Shape3DResource.generateTriangleMesh(
            vertices: [[-2, 1.84, -3], [-2, 1.84, 3], [6, 1.84, 3], [6, 1.84, -3]], indices: [0, 1, 2, 0, 2, 3]
        )
        fixture.app.main.spawn { PhysicsBody3DComponent(shapes: [ceiling], mode: .static, isTrigger: sensor); Transform() }
        await fixture.step(3)
        try fixture.move([2, 0, 0])
        await fixture.step(90)
        let position = try fixture.position()
        #expect(sensor ? position.x > 2.8 : position.x < 1)
        #expect(sensor ? abs(position.y - 0.08) < 0.012 : position.y + 1.8 <= 1.841)
    }

    @Test(arguments: [Float(0.08), 0.10])
    func highSpeedCannotSkipATooTallThinStone(rise: Float) async throws {
        let fixture = try await Fixture(height: 1.8)
        fixture.box(size: [0.02, rise, 8], at: [1, rise / 2, 0])
        await fixture.step(3)
        try fixture.move([500, 0, 0])
        await fixture.step(1)
        let position = try fixture.position()
        #expect(rise < 0.09 ? position.x > 8 : position.x < 0.9)
        #expect(position.y <= 0.096 && position.y >= -0.012)
        #expect(try fixture.state().velocity.x <= 500.001)
    }

    @Test(arguments: [false, true])
    func highSpeedStepDoesNotTunnelThroughTheWallBehindIt(sharedMesh: Bool) async throws {
        let fixture = try await Fixture(height: 1.8)
        if sharedMesh {
            let shape = try Shape3DResource.generateTriangleMesh(vertices: [
                [0.8, 0.09, -4], [1.2, 0.09, -4], [1.2, 0.09, 4], [0.8, 0.09, 4],
                [0.8, 0, -4], [0.8, 0, 4], [2, 0, -4], [2, 4, -4], [2, 4, 4], [2, 0, 4]
            ], indices: [0, 2, 1, 0, 3, 2, 4, 3, 0, 4, 5, 3, 6, 8, 7, 6, 9, 8])
            fixture.app.main.spawn { PhysicsBody3DComponent(shapes: [shape], mode: .static); Transform() }
        } else {
            fixture.box(size: [0.4, 0.09, 8], at: [1, 0.045, 0])
            fixture.box(size: [0.02, 4, 8], at: [2, 2, 0])
        }
        await fixture.step(3)
        try fixture.move([500, 0, 0])
        // The exact 9 cm limit may first land on the rounded front edge while the
        // controller settles out of floor slop. No intermediate tick may cross the wall.
        for _ in 0..<4 {
            await fixture.step(1)
            #expect(try fixture.position().x < 1.62)
        }
        let position = try fixture.position()
        #expect(position.x > 0.8 && position.x < 1.62)
        #expect(try fixture.position().y <= 0.096)
    }

    @Test func supportSlopCannotHideAnInitialLateralWallOverlap() async throws {
        let fixture = try await Fixture(height: 1.8)
        fixture.box(size: [0.02, 4, 8], at: [1, 2, 0])
        await fixture.step(3)
        var transform = try #require(fixture.actor.components[Transform.self])
        transform.position.x = 0.594 // Four mm inside the wall's left face at .99.
        fixture.actor.components[Transform.self] = transform
        try fixture.move([500, 0, 0])
        await fixture.step(1)
        #expect(try fixture.position().x < 0.61)
    }

    @Test(arguments: [false, true])
    func genuineSphereAndHorizontalCapsuleDomesRemainWalkable(capsule: Bool) async throws {
        let fixture = try await Fixture(height: 1.8)
        if capsule {
            let world = try #require(fixture.app.main.physicsWorld3D)
            var bodyDef = b3DefaultBodyDef()
            let body = unsafe b3CreateBody(world.worldId, &bodyDef)
            var shapeDef = b3DefaultShapeDef()
            var shape = b3Capsule(center1: b3Vec3(x: 1.7, y: -0.8, z: -2), center2: b3Vec3(x: 1.7, y: -0.8, z: 2), radius: 1)
            _ = unsafe b3CreateCapsuleShape(body, &shapeDef, &shape)
        } else {
            fixture.app.main.spawn { PhysicsBody3DComponent(shapes: [.generateSphere(radius: 1)], mode: .static); Transform(position: [1.7, -0.8, 0]) }
        }
        await fixture.step(3)
        try fixture.move([2, 0, 0])
        var maximumY: Float = 0
        for _ in 0..<120 {
            await fixture.step(1)
            maximumY = max(maximumY, try fixture.position().y)
        }
        let final = try fixture.position()
        #expect(maximumY > 0.18 && final.x > 3.6)
        #expect(try fixture.state().isGrounded)
    }

    @Test(arguments: [Vector3(-2, 0, 0), Vector3(1.4142135, 0, 1.4142135)])
    func backwardAndDiagonalStepsFollowTheRequestedDirection(velocity: Vector3) async throws {
        let fixture = try await Fixture(height: 1.8)
        let sign: Float = velocity.x < 0 ? -1 : 1
        fixture.box(size: [8, 0.08, 8], at: [sign * 5, 0.04, 0])
        await fixture.step(3)
        try fixture.move(velocity)
        await fixture.step(90)
        #expect(try fixture.position().x * sign > 2 && abs(fixture.position().y - 0.08) < 0.012)
        #expect(try fixture.state().velocity.length < 2.01)
        #expect(try fixture.position().z >= 0)
    }

    @Test func stairsAscendAndDescendWithoutAddingHorizontalEnergyOrLargeVerticalSnaps() async throws {
        let fixture = try await Fixture(height: 1.8)
        for index in 0..<3 {
            let rise = Float(index + 1) * 0.08
            fixture.box(size: [0.6, rise, 4], at: [1.3 + Float(index) * 0.6, rise / 2, 0])
        }
        fixture.box(size: [6, 0.24, 4], at: [5.8, 0.12, 0])
        await fixture.step(3)
        for direction: Float in [1, -1] {
            try fixture.move([direction * 2, 0, 0])
            for tick in 0..<120 {
                let before = try fixture.position()
                await fixture.step(1)
                let rise = try fixture.position().y - before.y
                #expect(rise <= 0.096 && rise >= -0.166)
                let velocity = try fixture.state().velocity
                let after = try fixture.position()
                #expect(Vector3(velocity.x, 0, velocity.z).length <= 2.001, "direction=\(direction), tick=\(tick), before=\(before), after=\(after)")
            }
            #expect(direction > 0 ? try fixture.position().y > 0.22 : abs(try fixture.position().y) < 0.012)
            #expect(try fixture.state().isGrounded)
        }
    }

    @MainActor
    private struct Fixture {
        let app: AppWorlds
        let actor: Entity

        init(height: Float) async throws {
            app = AppWorlds(main: World())
            app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics3DPlugin()).addPlugin(TransformPlugin())
            try await app.build()
            actor = app.main.spawn { CharacterController3DComponent(radius: 0.4, height: height); Transform() }
            box(size: [40, 1, 40], at: [0, -0.5, 0])
        }

        func move(_ velocity: Vector3) throws {
            var controller = try state()
            controller.acceleration = 100_000
            controller.desiredVelocity = velocity
            actor.components[CharacterController3DComponent.self] = controller
        }

        func state() throws -> CharacterController3DComponent { try #require(actor.components[CharacterController3DComponent.self]) }
        func position() throws -> Vector3 { try #require(actor.components[Transform.self]).position }

        @discardableResult
        func box(size: Vector3, at position: Vector3) -> Entity {
            app.main.spawn {
                PhysicsBody3DComponent(shapes: [.generateBox(width: size.x, height: size.y, depth: size.z)], mode: .static)
                Transform(position: position)
            }
        }

        func step(_ count: Int) async {
            await app.main.runScheduler(.physicsSync)
            app.main.insertResource(FixedTime(deltaTime: 1 / 60))
            for _ in 0..<count {
                await app.main.runScheduler(.physicsStep)
                await app.main.runScheduler(.physicsWriteback)
                await app.main.runScheduler(.postUpdate)
            }
        }
    }
}
