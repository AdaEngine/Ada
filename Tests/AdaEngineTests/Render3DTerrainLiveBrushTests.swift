#if os(macOS) || os(Windows) || os(Linux)
    @_spi(Internal) @testable import AdaApp
    import AdaECS
    @_spi(Internal) @testable import AdaRender
    @testable import AdaScene
    import AdaUtils
    import Foundation
    import Testing

    extension Render3DGPUTests.TerrainMaterials {
        @Test("Live material brush pixels update on retained meshes, Undo and cancel prepared work")
        func terrainMaterialLiveBrushPixels() async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("TerrainLiveBrush-" + UUID().uuidString, isDirectory: true).standardizedFileURL
            try #require(directory.deletingLastPathComponent() == root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let scene = try await makeScene(in: directory, textured: true)
            let owner = scene.owner, app = scene.app
            let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
            func buffers() throws -> [TerrainTileCoordinate: ObjectIdentifier] {
                var result: [TerrainTileCoordinate: ObjectIdentifier] = [:]
                for child in owner.children {
                    guard let tile = child.components[TerrainTile3DComponent.self] else { continue }
                    let part = try #require(child.components[Mesh3DComponent.self]?.mesh.models.first?.parts.first)
                    result[tile.coordinate] = ObjectIdentifier(part.vertexBuffer)
                }
                return result
            }
            let before = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            let original = before.getPixel(x: 128, y: 64), originalBuffers = try buffers()
            try #require(original.red > 0.25 && original.blue > 0.25 && originalBuffers.count == 4)
            var settings = TerrainSurfaceBrushSettings(operation: .paintLayer, radius: 0.25)
            settings.layerID = 12; settings.shape = .hardRound
            let stroke = TerrainSurfaceBrushStroke(settings: settings, points: [.init(position: [0, 0, 0], time: 0)])
            let request = Terrain3DEdit(storage: storage, brush: stroke)
            owner.components[Terrain3DEdit.self] = request
            try await waitForMaterialEdit(app, owner: owner, id: request.id)
            let status = try #require(owner.components[Terrain3DEditStatus.self])
            try #require(status.phase == .applied, Comment(rawValue: status.error ?? "Missing edit diagnostic"))
            let delta = try #require(status.delta)
            for _ in 0..<4 { try await app.update() }
            let painted = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
            let pixel = painted.getPixel(x: 128, y: 64), seam = painted.getPixel(x: 127, y: 64)
            #expect(pixel.blue > 0.9 && pixel.red < 0.1 && seam.blue > 0.9 && seam.red < 0.1)
            #expect(try buffers() == originalBuffers)
            let undo = Terrain3DEdit(storage: storage, undoing: delta)
            owner.components[Terrain3DEdit.self] = undo
            try await waitForMaterialEdit(app, owner: owner, id: undo.id)
            for _ in 0..<4 { try await app.update() }
            let undone = try #require(try await scene.engine.renderDevice.readImage(from: scene.target)).getPixel(x: 128, y: 64)
            #expect(abs(undone.red - original.red) < 0.02 && abs(undone.blue - original.blue) < 0.02)
            #expect(try buffers() == originalBuffers)
            var source = try #require(owner.components[Terrain3DSource.self])
            source.maximumTileUpdatesPerFrame = 1
            owner.components[Terrain3DSource.self] = source
            let revision = storage.revision
            let canceled = Terrain3DEdit(storage: storage, brush: stroke)
            owner.components[Terrain3DEdit.self] = canceled
            let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(15))
            while clock.now < deadline {
                await app.main.runScheduler(.preUpdate)
                if owner.components[Terrain3DSourceStatus.self]?.preparedTileCount == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(owner.components[Terrain3DSourceStatus.self]?.preparedTileCount == 1)
            owner.components.remove(Terrain3DEdit.self)
            for _ in 0..<4 { try await app.update() }
            #expect(owner.components[Terrain3DEditStatus.self]?.phase == .cancelled && storage.revision == revision)
            let retained = try #require(try await scene.engine.renderDevice.readImage(from: scene.target)).getPixel(x: 128, y: 64)
            #expect(abs(retained.red - original.red) < 0.02 && abs(retained.blue - original.blue) < 0.02)
            #expect(try buffers() == originalBuffers)
        }
    }
#endif
