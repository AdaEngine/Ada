@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Rigid-body bounds and character capsules request regions outside the camera range")
    func physicsInterestsOutsideCamera() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        for x in [0, 20, 22] { try authored.allocateRegion(at: .init(x: x, z: 0)) }
        let file = try await save(authored, in: directory)
        let app = try await makeApp(physics: true)
        let source = Terrain3DSource(source: file.path, maximumResidentRegions: 3, streamingRadius: 128)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        app.main.spawn("Camera") {
            Transform(position: [128, 0, 128]); Camera()
        }
        let body = app.main.spawn("Wide dynamic body") {
            Transform(position: [5_200, 5, 128])
            PhysicsBody3DComponent(shapes: [.generateBox(width: 1_000, height: 1, depth: 1)], mass: 1, mode: .dynamic)
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.regionCoordinates == [0, 20, 22].map { .init(x: $0, z: 0) })
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [22 * 256 + 32, 10, 240], to: [22 * 256 + 32, -10, 240], radius: 0.25)
        #expect(fraction > 0.48 && fraction < 0.50)
        app.main.removeEntity(body.id, recursively: true)
        app.main.spawn("Distant character") {
            Transform(position: [22 * 256 + 128, 2, 128])
            CharacterController3DComponent()
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.regionCoordinates == [0, 22].map { .init(x: $0, z: 0) })
    }

    @Test("Terrain admission failure pauses physical movement, readiness resumes grounded simulation, and despawning the owner releases its hold")
    func physicsWaitsForTerrain() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        for x in [0, 20] { try authored.allocateRegion(at: .init(x: x, z: 0)) }
        let file = try await save(authored, in: directory)
        let app = try await makeApp(physics: true)
        app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        var source = Terrain3DSource(source: file.path, maximumResidentRegions: 1, streamingRadius: 128)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        app.main.spawn("Camera") {
            Transform(position: [128, 0, 128]); Camera()
        }
        let body = app.main.spawn("Falling body") {
            Transform(position: [20 * 256 + 128, 5, 128])
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.5)], mass: 1, mode: .dynamic)
        }
        let character = app.main.spawn("Waiting character") {
            Transform(position: [20 * 256 + 64, 5, 64])
            CharacterController3DComponent()
        }
        func tick(_ count: Int) async {
            await app.main.runScheduler(.physicsSync)
            for _ in 0..<count {
                await app.main.runScheduler(.physicsStep)
                await app.main.runScheduler(.physicsWriteback)
            }
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        await tick(8)
        #expect(body.components[Transform.self]?.position.y == 5)
        #expect(character.components[Transform.self]?.position.y == 5)
        source.maximumResidentRegions = 2
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        await tick(120)
        let height = try #require(body.components[Transform.self]?.position.y)
        #expect(height > 0.45 && height < 0.60)
        #expect(character.components[CharacterController3DComponent.self]?.isGrounded == true)
        source.maximumResidentRegions = 1
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        app.main.removeEntity(owner.id, recursively: true)
        await settle(app)
        let probe = app.main.spawn("New falling probe") {
            Transform(position: [20 * 256 + 128, 5, 128])
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.5)], mass: 1, mode: .dynamic)
        }
        await tick(8)
        #expect(try #require(probe.components[Transform.self]?.position.y) < 5)
    }

    @Test("A character teleported after preUpdate waits at fixed synchronization until its new terrain collision is resident")
    func rechecksPhysicsAtFixedStep() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        for x in [0, 20] { try authored.allocateRegion(at: .init(x: x, z: 0)) }
        let file = try await save(authored, in: directory)
        let app = try await makeApp(physics: true)
        app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        let source = Terrain3DSource(source: file.path, maximumResidentRegions: 2, streamingRadius: 128)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        app.main.spawn("Camera") {
            Transform(position: [128, 0, 128]); Camera()
        }
        let character = app.main.spawn("Character") {
            Transform(position: [128, 5, 128]); CharacterController3DComponent()
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.regionCoordinates == [.init(x: 0, z: 0)])
        character.components[Transform.self] = Transform(position: [20 * 256 + 128, 5, 128])
        await app.main.runScheduler(.physicsSync)
        await app.main.runScheduler(.physicsStep)
        await app.main.runScheduler(.physicsWriteback)
        #expect(character.components[Transform.self]?.position.y == 5)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.regionCoordinates == [0, 20].map { .init(x: $0, z: 0) })
        await app.main.runScheduler(.physicsSync)
        for _ in 0..<120 {
            await app.main.runScheduler(.physicsStep)
            await app.main.runScheduler(.physicsWriteback)
        }
        #expect(character.components[CharacterController3DComponent.self]?.isGrounded == true)
    }

    @Test("Readiness providers retain independent reasons on the same owner")
    func independentPhysicsReasons() async throws {
        let app = try await makeApp(physics: true)
        app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        let body = app.main.spawn("Body") {
            Transform(position: [0, 5, 0])
            PhysicsBody3DComponent(shapes: [.generateSphere()], mass: 1, mode: .dynamic)
        }
        let gate = try #require(app.main.getResource(PhysicsSimulationGate3D.self))
        gate.setPending(owner: body.id, reason: "terrain", pending: true)
        gate.setPending(owner: body.id, reason: "other collision provider", pending: true)
        gate.setPending(owner: body.id, reason: "terrain", pending: false)
        #expect(!gate.isReady && gate.pendingOwnerCount == 1)
        await app.main.runScheduler(.physicsSync)
        await app.main.runScheduler(.physicsStep)
        await app.main.runScheduler(.physicsWriteback)
        #expect(body.components[Transform.self]?.position.y == 5)
        gate.setPending(owner: body.id, reason: "other collision provider", pending: false)
        #expect(gate.isReady && gate.pendingOwnerCount == 0)
        await app.main.runScheduler(.physicsStep)
        await app.main.runScheduler(.physicsWriteback)
        #expect(try #require(body.components[Transform.self]?.position.y) < 5)
    }
}
