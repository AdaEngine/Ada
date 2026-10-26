@_spi(Internal) import AdaApp
import AdaECS
@testable import AdaPhysics
import AdaScripting
import AdaTransform
import Foundation
import Math
import Testing

@MainActor
@Suite(.serialized)
struct OverlapBox3DTests {
    private func app() async throws -> AppWorlds {
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(Physics3DPlugin(gravity: .zero))
        try await app.build()
        return app
    }

    private func meshBox(_ half: Vector3) throws -> Shape3DResource {
        var vertices: [Vector3] = []
        for z: Float in [-1, 1] {
            for y: Float in [-1, 1] {
                for x: Float in [-1, 1] { vertices.append([x * half.x, y * half.y, z * half.z]) }
            }
        }
        return try .generateTriangleMesh(vertices: vertices, indices: [
            0,2,3,0,3,1,4,5,7,4,7,6,0,4,6,0,6,2,1,3,7,1,7,5,2,6,7,2,7,3,0,1,5,0,5,4
        ])
    }

    @Test(arguments: [false, true])
    func neighbourCornerOverlapsDespiteClearCentreAndRotatingClearsIt(_ triangleMesh: Bool) async throws {
        let app = try await app()
        let floorShape = triangleMesh
            ? try Shape3DResource.generateTriangleMesh(vertices: [[-2,0,-2], [2,0,-2], [2,0,2], [-2,0,2]], indices: [0,2,1,0,3,2])
            : Shape3DResource.generateBox(width: 4, height: 0.1, depth: 4)
        let floor = app.main.spawn {
            PhysicsBody3DComponent(shapes: [floorShape], mode: .static)
            Transform(position: [0, triangleMesh ? 0 : -0.05, 0])
        }
        let height: Float = 0.072857
        let stepShape = triangleMesh ? try meshBox([0.8, height / 2, 0.14]) : .generateBox(width: 1.6, height: height, depth: 0.28)
        let step = app.main.spawn {
            PhysicsBody3DComponent(shapes: [stepShape], mode: .static)
            Transform(position: [0, height / 2, -0.28])
        }
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        #expect(physics.raycast(from: [0, 1, 0], to: [0, -1, 0])?.entityID == floor.id)
        let half: Vector3 = [0.045, 0.0175, 0.17]
        let clear = try #require(physics.overlapBox(center: [1.2, 0.0225, 0], halfExtents: half))
        #expect(!clear.hasOverlap && clear.entityID == nil) // Bottom is 5 mm above the actual floor.
        let blocked = try #require(physics.overlapBox(center: [0, 0.0225, 0], halfExtents: half))
        #expect(blocked.hasOverlap && blocked.entityID == step.id)
        let rotated = try #require(physics.overlapBox(center: [0, 0.0225, 0], halfExtents: half, rotation: Quat(axis: .up, angle: .pi / 2)))
        #expect(!rotated.hasOverlap && rotated.entityID == nil)
    }

    @Test func orientedThinWallUsesNarrowPhaseAndNormalizesQuaternion() async throws {
        let app = try await app()
        let wall = app.main.spawn {
            PhysicsBody3DComponent(shapes: [.generateBox(width: 0.08, height: 1, depth: 0.04)], mode: .static)
            Transform(rotation: Quat(axis: .up, angle: 0.3), position: [0.35, 0, 0.35])
        }
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let half: Vector3 = [0.6, 0.1, 0.025]
        let away = Quat(axis: .up, angle: .pi / 4), toward = Quat(axis: .up, angle: -.pi / 4)
        // Both query orientations have the same AABB, but only one intersects the wall.
        #expect(try #require(physics.overlapBox(center: .zero, halfExtents: half, rotation: away)).hasOverlap == false)
        let blocked = try #require(physics.overlapBox(center: .zero, halfExtents: half, rotation: toward))
        #expect(blocked.hasOverlap && blocked.entityID == wall.id)
        let scaled = Quat(x: toward.x * 2, y: toward.y * 2, z: toward.z * 2, w: toward.w * 2)
        #expect(physics.overlapBox(center: .zero, halfExtents: half, rotation: scaled)?.hasOverlap == true)
    }

    @Test func sensorsAndExcludedEntitiesAreFilteredWithoutStoppingTraversal() async throws {
        let app = try await app()
        let solid = app.main.spawn { PhysicsBody3DComponent(shapes: [.generateBox()], mode: .static); Transform() }
        let sensor = app.main.spawn { PhysicsBody3DComponent(shapes: [.generateBox()], mode: .static, isTrigger: true); Transform() }
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        #expect(physics.overlapBox(center: .zero, halfExtents: [0.1, 0.1, 0.1])?.entityID == solid.id)
        #expect(physics.overlapBox(center: .zero, halfExtents: [0.1, 0.1, 0.1], excluding: solid.id)?.hasOverlap == false)
        let result = try #require(physics.overlapBox(center: .zero, halfExtents: [0.1, 0.1, 0.1], excluding: solid.id, includeSensors: true))
        #expect(result.hasOverlap && result.entityID == sensor.id)
    }

    @Test func anUnassociatedShapeStillBlocksTheVolume() async throws {
        let app = try await app()
        let entity = app.main.spawn { PhysicsBody3DComponent(shapes: [.generateBox()], mode: .static); Transform() }
        await app.main.runScheduler(.physicsSync)
        let body = try #require(entity.components[PhysicsBody3DComponent.self]?.runtimeBody)
        body.entity = nil
        let physics = try #require(app.main.physicsWorld3D)
        let result = try #require(physics.overlapBox(center: .zero, halfExtents: [0.1, 0.1, 0.1], excluding: entity.id))
        #expect(result.hasOverlap && result.entityID == nil)
    }

    @Test func invalidInputsNeverReportClear() async throws {
        let app = try await app()
        let physics = try #require(app.main.physicsWorld3D)
        let invalid: [(Vector3, Vector3, Quat)] = [
            ([.nan, 0, 0], .one, .identity), ([0, .infinity, 0], .one, .identity),
            ([Float.greatestFiniteMagnitude, 0, 0], .one, .identity),
            (.zero, [0, 1, 1], .identity), (.zero, [-1, 1, 1], .identity),
            (.zero, [1, .nan, 1], .identity), (.zero, [1, 1, .infinity], .identity),
            (.zero, [Float.greatestFiniteMagnitude, 1, 1], .identity),
            (.zero, .one, Quat()), (.zero, .one, Quat(x: .nan, y: 0, z: 0, w: 1)),
            (.zero, .one, Quat(x: 0, y: 0, z: 0, w: .infinity)),
            (.zero, .one, Quat(x: 0, y: 0, z: 0, w: .greatestFiniteMagnitude))
        ]
        for (center, half, rotation) in invalid {
            #expect(physics.overlapBox(center: center, halfExtents: half, rotation: rotation) == nil)
        }
    }

    @Test func versionedRequestsFailClosedAndClearTransientResults() async throws {
        let app = try await app()
        let obstacle = app.main.spawn { PhysicsBody3DComponent(shapes: [.generateBox()], mode: .static); Transform() }
        var input = OverlapBox3DComponent()
        input.halfExtents = [0.1, 0.1, 0.1]; input.requestID = 1
        let query = app.main.spawn { input }
        await app.main.runScheduler(.physicsSync)
        await app.main.runScheduler(.physicsWriteback)
        var result = try #require(query.components[OverlapBox3DComponent.self])
        #expect(result.completedRequestID == 1 && result.hasOverlap && result.hitEntityID == obstacle.id)
        result.center = [4, 0, 0]; result.requestID = 2
        query.components[OverlapBox3DComponent.self] = result
        await app.main.runScheduler(.physicsWriteback)
        result = try #require(query.components[OverlapBox3DComponent.self])
        #expect(result.completedRequestID == 2 && !result.hasOverlap && result.hitEntityID == -1 && result.errorCode.isEmpty)
        result.halfExtents.x = .nan; result.requestID = 3
        query.components[OverlapBox3DComponent.self] = result
        await app.main.runScheduler(.physicsWriteback)
        result = try #require(query.components[OverlapBox3DComponent.self])
        #expect(result.completedRequestID == 3 && result.hasOverlap && result.hitEntityID == -1 && result.errorCode == "invalidBox")
        result.halfExtents = [0.1, 0.1, 0.1]
        query.components[OverlapBox3DComponent.self] = result
        await app.main.runScheduler(.physicsWriteback)
        #expect(query.components[OverlapBox3DComponent.self]?.errorCode == "invalidBox") // No new request.
        result.requestID = 4; query.components[OverlapBox3DComponent.self] = result
        await app.main.runScheduler(.physicsWriteback)
        #expect(query.components[OverlapBox3DComponent.self]?.hasOverlap == false)
        #expect(query.components[OverlapBox3DComponent.self]?.errorCode.isEmpty == true)
    }

    @Test func codableStoresInputsAndNeverRestoresStaleQueryResults() throws {
        var value = OverlapBox3DComponent()
        value.center = [1, 2, 3]; value.halfExtents = [0.2, 0.3, 0.4]; value.rotation = Quat(axis: .up, angle: 0.7)
        value.excludingEntityID = 42; value.includeSensors = true; value.requestID = 7
        value.completedRequestID = 7; value.hasOverlap = false; value.hitEntityID = 99; value.errorCode = "stale"
        let data = try JSONEncoder().encode(value)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["completedRequestID"] == nil && fields["hasOverlap"] == nil && fields["hitEntityID"] == nil && fields["errorCode"] == nil)
        let decoded = try JSONDecoder().decode(OverlapBox3DComponent.self, from: data)
        #expect(decoded.center == value.center && decoded.halfExtents == value.halfExtents && decoded.rotation == value.rotation)
        #expect(decoded.requestID == 7 && decoded.excludingEntityID == 42 && decoded.includeSensors)
        #expect(decoded.completedRequestID == -1 && decoded.hasOverlap && decoded.hitEntityID == -1 && decoded.errorCode.isEmpty)
        let defaults = try JSONDecoder().decode(OverlapBox3DComponent.self, from: Data("{}".utf8))
        #expect(defaults.rotation == .identity && defaults.completedRequestID == -1 && defaults.hasOverlap)
    }

    @Test func actualAdaScriptCanWriteTheBoxAndReadBothOverlapAndClear() async throws {
        let app = try await app()
        let obstacle = app.main.spawn {
            PhysicsBody3DComponent(shapes: [.generateBox()], mode: .static)
            Transform(position: [0, 0, 3])
        }
        let query = app.main.spawn { OverlapBox3DComponent() }
        let plugin = try AdaScriptPlugin(source: """
        @access(write: [OverlapBox3DComponent])
        @system(id: "box-overlap-contract")
        class BoxContract {
            @query(OverlapBox3DComponent) var boxes;
            func update(context) {
                for (var row in boxes) {
                    var box=row.overlapBox3DComponent;
                    if (box.requestID==0) {
                        box.center=[0.0,0.0,3.0]; box.halfExtents=[0.2,0.05,0.3];
                        box.rotation=[0.0,0.7071067811865476,0.0,0.7071067811865476];
                        box.excludingEntityID=-1; box.includeSensors=false; box.requestID=1;
                    } else if (box.completedRequestID==1 && box.hasOverlap && box.hitEntityID>=0 && box.errorCode=="") {
                        box.center=[10.0,0.0,3.0]; box.requestID=2;
                    } else if (box.completedRequestID==2 && !box.hasOverlap && box.hitEntityID==-1 && box.errorCode=="") {
                        box.requestID=3;
                    }
                }
            }
        }
        """, name: "BoxContract")
        defer { plugin.destroy(for: app) }
        plugin.setup(in: app)
        await app.main.runScheduler(.update)
        let input = try #require(query.components[OverlapBox3DComponent.self])
        #expect(input.requestID == 1 && input.center == [0, 0, 3] && input.halfExtents == [0.2, 0.05, 0.3])
        #expect(abs(input.rotation.y - 0.70710678) < 0.00001)
        await app.main.runScheduler(.physicsSync)
        await app.main.runScheduler(.physicsWriteback)
        #expect(query.components[OverlapBox3DComponent.self]?.hitEntityID == obstacle.id)
        await app.main.runScheduler(.update)
        #expect(query.components[OverlapBox3DComponent.self]?.requestID == 2)
        await app.main.runScheduler(.physicsWriteback)
        await app.main.runScheduler(.update)
        #expect(query.components[OverlapBox3DComponent.self]?.requestID == 3)
        #expect(plugin.diagnostics.isEmpty, "\(plugin.diagnostics)")
    }
}
