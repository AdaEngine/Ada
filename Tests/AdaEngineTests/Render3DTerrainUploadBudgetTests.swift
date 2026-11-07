#if os(macOS) || os(Windows) || os(Linux)
    @_spi(Internal) @testable import AdaApp
    import AdaAssets
    import AdaECS
    @_spi(Internal) @testable import AdaRender
    @testable import AdaScene
    import AdaUtils
    import Foundation
    import Testing

    extension Render3DGPUTests.TerrainMaterials {
        @Test("Palette upload paces real GPU bytes while retaining the published generation")
        func terrainMaterialPacedArrayPixels() async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("TerrainPacedArrays-" + UUID().uuidString, isDirectory: true).standardizedFileURL
            try #require(directory.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = try await makeScene(in: directory, textured: true)
            let owner = scene.owner, app = scene.app
            let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
            let originalBuffers = try materialBuffers(owner)
            let original = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            try #require(original.getPixel(x: 80, y: 64).red > 0.8)
            try Image(width: 256, height: 256, color: .red).writePNG(to: directory.appendingPathComponent("large-red.png"))
            try Image(width: 256, height: 256, color: .blue).writePNG(to: directory.appendingPathComponent("large-blue.png"))
            let layers = (1...5).map { TerrainLayerReference(id: UInt16($0), name: "Layer \($0)", albedoPath: $0 == 5 ? "large-blue.png" : "large-red.png") }
            let palette = TerrainMaterialPalette(layers: layers, fallbackLayerID: 5)
            var regions: [TerrainRegionAsset] = []
            for coordinate in storage.resourceCoordinates {
                if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
            }
            let manifest = TerrainManifestAsset(spacing: storage.spacing, originX: storage.origin.x, originZ: storage.origin.y, materials: palette)
            try await AssetsManager.saveTerrainRegions(regions, manifest: manifest, at: directory.appendingPathComponent("world.aterrain").path)
            let metrics = TerrainMaterialUploadMetrics()
            app.main.insertResource(metrics)
            var source = try #require(owner.components[Terrain3DSource.self])
            source.reloadGeneration &+= 1
            owner.components[Terrain3DSource.self] = source
            let key = TerrainSourceKey(source)
            var uploadFrames = 0
            let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(20))
            while clock.now < deadline {
                let previous = metrics.uploadedBytes
                try await app.update()
                let uploaded = metrics.uploadedBytes - previous
                #expect(uploaded <= 1_048_576, "Shared palette image transfers must stay within one MiB per update")
                if uploaded > 0 { uploadFrames += 1 }
                if owner.components[TerrainSourceState.self]?.key == key, owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
                #expect(try materialBuffers(owner) == originalBuffers)
                let retained = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
                #expect(retained.getPixel(x: 80, y: 64).red > 0.8)
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(owner.components[TerrainSourceState.self]?.key == key && owner.components[Terrain3DSourceStatus.self]?.isReady == true)
            #expect(metrics.uploadedBytes > 1_048_576 && uploadFrames >= 2)
            for _ in 0..<4 { try await app.update() }
            let published = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            let pixel = published.getPixel(x: 80, y: 64)
            #expect(pixel.blue > 0.9 && pixel.red < 0.1, "The last uploaded array slice must reach actual terrain pixels")
            let total = metrics.uploadedBytes
            for _ in 0..<4 { try await app.update() }
            #expect(metrics.uploadedBytes == total, "Idle frames must retain the completed palette")
        }
    }
#endif
