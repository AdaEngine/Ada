@_spi(Internal) @testable import AdaApp
import AdaECS
@testable import AdaPhysics
import AdaTransform
import Foundation
import Math
import Testing

@MainActor
@Suite(.serialized)
struct Physics3DGeometryTests {
    let app: AppWorlds

    init() async throws {
        app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics3DPlugin()).addPlugin(TransformPlugin())
        try await app.build()
    }

    @Test
    func triangleColliderSupportsFallingBodiesAndGroundedDownhillMovement() async throws {
        let shape = try slope()
        app.main.spawn {
            PhysicsBody3DComponent(shapes: [shape], mode: .static)
            Transform()
        }
        let actor = app.main.spawn {
            CharacterController3DComponent()
            Transform(position: [3, 3, 0])
        }
        let sphere = app.main.spawn {
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.2)], mass: 1, mode: .dynamic)
            Transform(position: [0, 3, 2])
        }
        await step(120)
        #expect(try #require(actor.components[CharacterController3DComponent.self]).isGrounded)
        #expect(abs(try #require(actor.components[Transform.self]).position.y - 0.75) < 0.05)
        let bodyPosition = try #require(sphere.components[Transform.self]).position
        #expect(bodyPosition.x > -4.1)
        #expect(abs(bodyPosition.y - bodyPosition.x / 4 - 0.2) < 0.06)
        var controller = try #require(actor.components[CharacterController3DComponent.self])
        controller.desiredVelocity = [-2, 0, 0]
        actor.components[CharacterController3DComponent.self] = controller
        for _ in 0..<120 {
            await step(1)
            #expect(try #require(actor.components[CharacterController3DComponent.self]).isGrounded)
        }
        let position = try #require(actor.components[Transform.self]).position
        #expect(position.x < 0 && position.x > -1.5)
        #expect(abs(position.y - position.x / 4) < 0.05)
    }

    @Test
    func sphereSweepFindsNearestSolidAndIgnoresSensors() async throws {
        for (x, sensor) in [(Float(1), true), (3, false), (5, false)] {
            app.main.spawn {
                PhysicsBody3DComponent(shapes: [.generateBox(width: 0.2, height: 4, depth: 4)], mode: .static, isTrigger: sensor)
                Transform(position: [x, 0, 0])
            }
        }
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: .zero, to: [10, 0, 0], radius: 0.25)
        #expect(abs(fraction - 0.265) < 0.005)
        #expect(physics.sphereCastFraction(from: [3, 0, 0], to: .zero, radius: 0.25) == 0)
        #expect(physics.sphereCastFraction(from: [1, 0, 0], to: [1, 5, 0], radius: 0.25) == 1)
        #expect(physics.sphereCastFraction(from: .zero, to: [.nan, 0, 0], radius: 0.25) == 0)
    }

    @Test
    func sphereSweepCollidesWithSlopedTerrain() async throws {
        let shape = try slope()
        app.main.spawn {
            PhysicsBody3DComponent(shapes: [shape], mode: .static)
            Transform()
        }
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [0, 3, 0], to: [0, -3, 0], radius: 0.25)
        #expect(fraction > 0.44 && fraction < 0.48)
    }

    @Test
    func validatesGeometryAndRoundTripsStaticMesh() throws {
        let shape = try slope()
        let data = try JSONEncoder().encode(shape)
        #expect(try JSONDecoder().decode(Shape3DResource.self, from: data) == shape)
        #expect(throws: Shape3DResource.TriangleMeshError.self) {
            try Shape3DResource.generateTriangleMesh(vertices: [.zero, .right, .up], indices: [0, 1, 5])
        }
        #expect(throws: Shape3DResource.TriangleMeshError.self) {
            try Shape3DResource.generateTriangleMesh(vertices: [.zero, .right, .right], indices: [0, 1, 2])
        }
        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var fixture = try #require(document["fixture"] as? [String: Any])
        var triangle = try #require(fixture["triangleMesh"] as? [String: Any])
        var mesh = try #require(triangle["_0"] as? [String: Any])
        mesh["indices"] = [0, 1, 9]
        triangle["_0"] = mesh
        fixture["triangleMesh"] = triangle
        document["fixture"] = fixture
        #expect(throws: Shape3DResource.TriangleMeshError.self) {
            try JSONDecoder().decode(Shape3DResource.self, from: JSONSerialization.data(withJSONObject: document))
        }
    }

    private func slope() throws -> Shape3DResource {
        try .generateTriangleMesh(vertices: [[-4, -1, -4], [-4, -1, 4], [4, 1, 4], [4, 1, -4]], indices: [0, 1, 2, 0, 2, 3])
    }

    private func step(_ count: Int) async {
        await app.main.runScheduler(.physicsSync)
        app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        for _ in 0..<count {
            await app.main.runScheduler(.physicsStep)
            await app.main.runScheduler(.physicsWriteback)
        }
    }
}
