#if os(macOS) || os(Windows) || os(Linux)
    @_spi(Internal) @testable import AdaApp
    import AdaCorePipelines
    @_spi(Internal) @testable import AdaRender
    import AdaUtils
    import Foundation
    import Testing

    extension Render3DGPUTests.TerrainMaterials {
        @Test("Portable tracing preserves terrain layer colors through an explicit raster fallback")
        func terrainMaterialTracingFallbackPixels() async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("TerrainTracingFallback-" + UUID().uuidString, isDirectory: true).standardizedFileURL
            try #require(directory.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = try await makeScene(in: directory, textured: true)
            let original = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            try #require(original.getPixel(x: 80, y: 64).red > 0.8 && original.getPixel(x: 176, y: 64).blue > 0.8)
            var environment = try #require(scene.camera.components[Environment3D.self])
            environment.pathTracing.isEnabled = true
            scene.camera.components[Environment3D.self] = environment
            for _ in 0..<4 { try await scene.app.update() }
            let statistics = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DPathTracingStatistics.self))
            let status = try #require(statistics.snapshots.values.first)
            #expect(status.failure?.contains("Terrain material layers require raster rendering") == true)
            #expect(status.encodedFrames == 0)
            let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            let low = image.getPixel(x: 80, y: 64), high = image.getPixel(x: 176, y: 64)
            #expect(low.red > 0.8 && low.blue < 0.1 && high.blue > 0.8 && high.red < 0.1)
        }
    }
#endif
