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
            environment.pathTracing.intersection = .software
            scene.camera.components[Environment3D.self] = environment
            for _ in 0..<4 { try await scene.app.update() }
            let statistics = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DPathTracingStatistics.self))
            let status = try #require(statistics.snapshots.values.first)
            #expect(status.failure?.contains("Terrain material layers require raster rendering") == true)
            #expect(status.encodedFrames == 0)
            let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            let low = image.getPixel(x: 80, y: 64)
            let high = image.getPixel(x: 176, y: 64)
            #expect(low.red > 0.8 && low.blue < 0.1 && high.blue > 0.8 && high.red < 0.1)
        }

        #if os(Windows) || os(Linux)
            @Test("Hardware primary rays shade the authored layer textures continuously across a region boundary")
            func terrainHardwareTracingLayeredRegions() async throws {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerrainTracingLayers-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: true, view: .none, crossesRegionBoundary: true)
                guard scene.engine.renderDevice.supportsRayQueries else {
                    return
                }
                var environment = try #require(scene.camera.components[Environment3D.self])
                environment.pathTracing = .init(isEnabled: true, samplesPerPixel: 2, maximumBounces: 1, resolutionScale: 1)
                environment.pathTracing.denoiser = .off
                environment.pathTracing.rasterFirstHit = false
                scene.camera.components[Environment3D.self] = environment
                for _ in 0..<8 { try await scene.app.update() }
                let statistics = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DPathTracingStatistics.self))
                let status = try #require(statistics.snapshots[String(scene.camera.id)])
                #expect(status.implementation == "vulkan-ray-query")
                #expect(status.encodedFrames > 0)
                #expect(status.failure == nil && status.intersectionFallback == nil)
                #expect(!status.hybridFirstHit)
                let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
                let low = image.getPixel(x: 80, y: 64)
                let high = image.getPixel(x: 176, y: 64)
                #expect(low.red > low.blue + 0.1 && high.blue > high.red + 0.1)
                let left = image.getPixel(x: 127, y: 64)
                let right = image.getPixel(x: 128, y: 64)
                #expect(left.red > 0.1 && left.blue > 0.1 && right.red > 0.1 && right.blue > 0.1)
                #expect(abs(left.red - right.red) < 0.12 && abs(left.blue - right.blue) < 0.12)

                environment.fog = Fog3D(isEnabled: true, color: .green, density: 0.3, heightFalloff: 0.12, startDistance: 0.5)
                scene.camera.components[Environment3D.self] = environment
                for _ in 0..<4 { try await scene.app.update() }
                let fogged = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
                #expect(fogged.getPixel(x: 80, y: 64).green > low.green + 0.25)
                #expect(abs(fogged.getPixel(x: 0, y: 64).green - image.getPixel(x: 0, y: 64).green) < 0.03)
            }
        #endif
    }
#endif
