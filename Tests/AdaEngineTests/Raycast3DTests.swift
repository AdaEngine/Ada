@_spi(Internal) @testable import AdaApp
import AdaECS
@testable import AdaPhysics
import AdaScripting
import AdaTransform
import Foundation
import Math
import Testing

@MainActor
@Suite(.serialized)
struct Raycast3DTests {
    private func app() async throws -> AppWorlds {
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(Physics3DPlugin(gravity: .zero))
        try await app.build()
        return app
    }

    @Test func closestSurfaceOccludesTargetsAndSensorsAreOptional() async throws {
        let app = try await app()
        func box(_ z: Float, sensor: Bool = false) -> Entity {
            app.main.spawn {
                PhysicsBody3DComponent(shapes: [.generateBox()], mode: .static, isTrigger: sensor)
                Transform(position: [0, 0, z])
            }
        }
        let target = box(9)
        let wall = box(5)
        let sensor = box(2, sensor: true)
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let hit = try #require(physics.raycast(from: .zero, to: [0, 0, 12]))
        #expect(hit.entityID == wall.id)
        #expect(abs(hit.distance - 4.5) < 0.001)
        #expect(hit.normal.z < -0.99)
        #expect(physics.raycast(from: .zero, to: [0, 0, 12], excluding: wall.id)?.entityID == target.id)
        #expect(physics.raycast(from: .zero, to: [0, 0, 12], includeSensors: true)?.entityID == sensor.id)
        #expect(physics.raycast(from: .zero, to: .zero) == nil)
        #expect(physics.raycast(from: [.nan, 0, 0], to: [0, 0, 12]) == nil)
    }

    @Test func requestResultsAreVersionedAndReadableFromAdaScript() async throws {
        let app = try await app()
        app.main.spawn {
            PhysicsBody3DComponent(shapes: [.generateBox()], mode: .static)
            Transform(position: [0, 0, 5])
        }
        let query = app.main.spawn { Raycast3DComponent() }
        let plugin = try AdaScriptPlugin(source: """
        @system(id: "ray-contract")
        class RayContract {
            @query(Raycast3DComponent) var rays;
            func update(context) {
                for (var row in rays) {
                    if (row.raycast3DComponent.requestID == 0) {
                        row.raycast3DComponent.origin = [0.0, 0.0, 0.0];
                        row.raycast3DComponent.destination = [0.0, 0.0, 10.0];
                        row.raycast3DComponent.requestID = 1;
                    } else if (row.raycast3DComponent.completedRequestID == 1 && row.raycast3DComponent.hasHit) {
                        row.raycast3DComponent.requestID = 2;
                    }
                }
            }
        }
        """, name: "RayContract")
        plugin.setup(in: app)
        await app.main.runScheduler(.update)
        await app.main.runScheduler(.physicsSync)
        await app.main.runScheduler(.physicsWriteback)
        let first = try #require(query.components[Raycast3DComponent.self])
        #expect(first.completedRequestID == 1 && first.hasHit)
        await app.main.runScheduler(.update)
        #expect(query.components[Raycast3DComponent.self]?.requestID == 2)
        #expect(plugin.diagnostics.isEmpty)
        let decoded = try JSONDecoder().decode(Raycast3DComponent.self, from: JSONEncoder().encode(first))
        #expect(decoded.completedRequestID == -1 && !decoded.hasHit)
    }
}
