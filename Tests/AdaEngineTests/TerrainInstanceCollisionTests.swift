@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Flagged nearby props collide within count/distance limits under reflected parent transforms", arguments: [false, true])
    func terrainNearbyInstanceCollision(transformed: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try terrainGLTFDocument(normals: 3).write(to: directory.appendingPathComponent("prop.gltf"))
        let instances = try [
            TerrainRegionInstance(id: 1, prototypeID: 7, localPosition: [10, 1, 10], flags: [.collision]),
            TerrainRegionInstance(id: 2, prototypeID: 7, localPosition: [30, 1, 30], flags: [.collision]),
            TerrainRegionInstance(id: 3, prototypeID: 7, localPosition: [10, 1, 11], flags: [.collision]),
            TerrainRegionInstance(id: 4, prototypeID: 7, localPosition: [10, 1, 12], flags: []),
        ]
        let region = TerrainRegionAsset(x: 0, z: 0, tiles: [.init(x: 0, z: 0)], pages: [], instances: instances)
        let file = directory.appendingPathComponent("world.aterrain")
        try await AssetsManager.saveTerrainRegions([region], manifest: .init(meshPrototypes: [.init(id: 7, assetPath: "prop.gltf")]), at: file.path)
        let app = try await makeApp(physics: true)
        let pose = transformed ? Transform(rotation: Quat(axis: [0, 1, 0], angle: .pi / 2), scale: [-2, 1.5, 1], position: [3, 2, -4]) : Transform()
        let matrix = pose.matrix
        let parent = app.main.spawn("Placement parent") { pose }
        let owner = app.main.spawn("Collidable terrain props") {
            Transform()
            Terrain3DSource(
                source: file.path,
                maximumLOD: 0,
                streamingRadius: nil,
                instanceCollision: .init(distance: 4, maximumCount: 1, maximumUpdatesPerFrame: 1)
            )
        }
        parent.addChild(owner)
        let camera = app.main.spawn("Nearby prop camera") { Transform(position: (matrix * Vector4(10, 5, 10, 1)).xyz); Camera() }
        await settle(app)
        try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let originalBuffers = try buffers(owner)
        let physics = try #require(app.main.physicsWorld3D)
        func fraction(x: Float, z: Float) -> Float {
            physics.sphereCastFraction(
                from: (matrix * Vector4(x + 0.2, 1.2, z + 2, 1)).xyz,
                to: (matrix * Vector4(x + 0.2, 1.2, z - 2, 1)).xyz,
                radius: 0.02
            )
        }
        let near = fraction(x: 10, z: 10), far = fraction(x: 30, z: 30)
        #expect(near > 0.4 && near < 0.6)
        #expect(far == 1)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
        camera.components[Transform.self]?.position = (matrix * Vector4(30, 5, 30, 1)).xyz
        await settle(app)
        let moved = fraction(x: 30, z: 30)
        #expect(moved > 0.4 && moved < 0.6)
        #expect(fraction(x: 10, z: 10) == 1)
        #expect(owner.components[Terrain3DSourceStatus.self]?.instanceColliderCount == 1)
        #expect(try buffers(owner) == originalBuffers)
    }
}
