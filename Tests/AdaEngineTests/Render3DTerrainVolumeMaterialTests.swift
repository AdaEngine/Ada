#if os(macOS) || os(Windows) || os(Linux)
    @_spi(Internal) @testable import AdaApp
    import AdaEngine
    @_spi(Internal) @testable import AdaRender
    @testable import AdaScene
    import Foundation
    import Testing

    extension Render3DGPUTests.TerrainMaterials {
        @Test("Volume triangle atlas shades separate height strata through the real terrain GPU pipeline")
        func terrainVolumeMaterialAtlasPixels() async throws {
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("TerrainVolumeMaterial-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = try await makeScene(in: directory, textured: false)
            let state = try #require(scene.owner.components[TerrainSourceState.self])
            let storage = try #require(state.storage)
            let maps = try #require(state.materialArrays)
            let cache = try #require(state.residency?.cache)
            let palette = try #require(await cache.manifest.materials)
            var descriptor = MeshDescriptor(name: "Two material strata")
            descriptor.positions = MeshBuffer([
                Vector3(-2, 0, -1), [0, 0, -1], [-2, 0, 1], [0, 0, 1],
                [0, 10, -1], [2, 10, -1], [0, 10, 1], [2, 10, 1],
            ])
            descriptor.normals = MeshBuffer([Vector3](repeating: .up, count: 8))
            descriptor.indicies = [0, 2, 1, 1, 2, 3, 4, 6, 5, 5, 6, 7]
            let prepared = try TerrainSourceMaterials.prepareVolume(descriptor, storage: storage, resolver: TerrainMaterialResolver(palette))
            let material = try TerrainSourceMaterialUpload.make(
                descriptor: prepared.descriptor,
                coordinate: .init(x: 0, z: 0),
                storage: storage,
                palette: palette,
                maps: maps,
                color: .one,
                device: scene.engine.renderDevice
            )
            scene.owner.components.remove(Terrain3DSource.self)
            scene.app.main.spawn("Volume material proof") {
                Transform(rotation: Quat(axis: .right, angle: -Float.pi / 2))
                Mesh3DComponent(mesh: Mesh.generate(from: [TerrainSourceMaterials.displayGeometry(prepared.descriptor)], renderDevice: scene.engine.renderDevice), materials: [material])
            }
            scene.camera.components[Transform.self] = Transform(position: [0, 0, -20])
            for _ in 0..<4 { try await scene.app.update() }
            let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            let artifact = GoldenFrame.outputDirectory.appendingPathComponent("terrain-volume-material-atlas.png")
            try image.writePNG(to: artifact)
            print("TERRAIN-VOLUME-MATERIAL-GPU-IMAGE", artifact.path)
            let low = image.getPixel(x: 80, y: 64), high = image.getPixel(x: 176, y: 64)
            #expect(low.red > 0.8 && low.green < 0.1 && low.blue < 0.1)
            #expect(high.blue > 0.8 && high.red < 0.1 && high.green < 0.1)
        }
    }
#endif
