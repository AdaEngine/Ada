@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Disabling prop collision during an invalid configuration releases its actual bodies")
    func terrainPropRecoveryDisable() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await collisionFixture(directory, count: 1)
        let app = try await makeApp(physics: true)
        var source = Terrain3DSource(source: file.path, maximumLOD: 0, streamingRadius: nil)
        let owner = app.main.spawn("Recovery disable") { Transform(); source }
        app.main.spawn("Camera") { Transform(position: [30, 5, 30]); Camera() }
        await settle(app)
        try #require(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
        let physics = try #require(app.main.physicsWorld3D)
        func fraction() -> Float { physics.sphereCastFraction(from: [30.2, 1.2, 32], to: [30.2, 1.2, 28], radius: 0.02) }
        #expect(fraction() < 0.6)
        source.maximumLOD = 7
        source.generatesCollision = false
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 0)
        #expect(owner.children.allSatisfy { $0.components[PhysicsBody3DComponent.self] == nil })
        #expect(fraction() == 1)
    }

    @Test("Placement-only terrain recovers the new collision pose after moving during invalid configuration")
    func terrainPropRecoveryPose() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await collisionFixture(directory, count: 1, surface: false)
        let app = try await makeApp(physics: true)
        var source = Terrain3DSource(source: file.path, maximumLOD: 0, streamingRadius: nil)
        let owner = app.main.spawn("Recovery pose") { Transform(); source }
        app.main.spawn("Camera") { Transform(position: [30, 5, 30]); Camera() }
        await settle(app)
        try #require(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
        let physics = try #require(app.main.physicsWorld3D)
        func fraction(_ x: Float) -> Float { physics.sphereCastFraction(from: [x + 0.2, 1.2, 32], to: [x + 0.2, 1.2, 28], radius: 0.02) }
        #expect(fraction(30) < 0.6)
        source.maximumLOD = 7
        owner.components[Transform.self]?.position = [50, 0, 0]
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
        #expect(fraction(30) < 0.6)
        source.maximumLOD = 0
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(fraction(80) > 0.4 && fraction(80) < 0.6)
        #expect(fraction(30) == 1)
    }

    @Test("Camera collection overflow conservatively retains bounded prop collision")
    func terrainPropRecoveryCameraOverflow() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await collisionFixture(directory, count: 1)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Camera overflow") {
            Transform(); Terrain3DSource(source: file.path, maximumLOD: 0, streamingRadius: nil)
        }
        for index in 0..<16 { app.main.spawn("Camera \(index)") { Transform(position: [30, 5, 30]); Camera() } }
        await settle(app)
        try #require(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
        let overflow = app.main.spawn("Overflow camera") { Transform(position: [30, 5, 30]); Camera() }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
        let physics = try #require(app.main.physicsWorld3D)
        #expect(physics.sphereCastFraction(from: [30.2, 1.2, 32], to: [30.2, 1.2, 28], radius: 0.02) < 0.6)
        app.main.removeEntity(overflow.id)
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
    }
}
