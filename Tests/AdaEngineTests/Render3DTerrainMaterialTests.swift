#if os(macOS) || os(Windows) || os(Linux)
    @_spi(Internal) @testable import AdaApp
    import AdaAssets
    import AdaCorePipelines
    import AdaECS
    @_spi(Internal) @testable import AdaRender
    @testable import AdaScene
    import AdaTransform
    import AdaUtils
    import Foundation
    import Math
    import Testing

    extension Render3DGPUTests {
        @Suite("Terrain material pixels", .enabled(if: GoldenFrame.isEnabled))
        @MainActor
        struct TerrainMaterials {
            @Test("Height-selected layer colors blend continuously across generated source tile borders", arguments: [false, true])
            func terrainMaterialPalettePixels(textured: Bool) async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainMaterialGPU-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: textured)
                let target = scene.target, engine = scene.engine
                let image = try #require(try await engine.renderDevice.readImage(from: target))
                try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
                let artifact = GoldenFrame.outputDirectory.appendingPathComponent("terrain-height-materials-" + UUID().uuidString + ".png")
                try image.writePNG(to: artifact)
                print("TERRAIN-MATERIAL-GPU-IMAGE", artifact.path)
                let low = image.getPixel(x: 80, y: 64), high = image.getPixel(x: 176, y: 64)
                // This first control establishes that the projected source geometry covers the tested pixels.
                #expect(low.red + low.green + low.blue > 0.2 && high.red + high.green + high.blue > 0.2)
                #expect(low.red > 0.8 && low.green < 0.1 && low.blue < 0.1)
                #expect(high.blue > 0.8 && high.red < 0.1 && high.green < 0.1)
                let middle = image.getPixel(x: 128, y: 64)
                #expect(middle.red > 0.25 && middle.blue > 0.25 && middle.green < 0.1)
                let seam = image.getPixel(x: 127, y: 64)
                #expect(abs(seam.red - middle.red) < 0.12 && abs(seam.blue - middle.blue) < 0.12)
            }

            @Test("Height maps change material transitions while missing maps retain ordinary blending", arguments: ["off", "on", "missing"])
            func terrainMaterialHeightBlendPixels(mode: String) async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainHeightBlend-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: true, heightBlend: mode != "off", missingHeight: mode == "missing")
                let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
                let low = image.getPixel(x: 80, y: 64), high = image.getPixel(x: 176, y: 64)
                try #require(low.red > 0.8 && low.blue < 0.1 && high.blue > 0.8 && high.red < 0.1)
                let middle = image.getPixel(x: 128, y: 64)
                if mode == "on" {
                    #expect(middle.blue > 0.9 && middle.red < 0.1)
                } else {
                    #expect(middle.red > 0.25 && middle.blue > 0.25)
                }
                let warnings = try #require(scene.owner.components[Terrain3DSourceStatus.self]).warnings
                #expect(warnings.count == (mode == "missing" ? 2 : 0))
            }

            @Test("Obsolete palette GPU allocations release after source reload and removal", .enabled(if: GoldenFrame.activeBackend == .webgpu))
            func terrainMaterialGPUTexturesRelease() async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainMaterialGPU-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: true)
                let app = scene.app, owner = scene.owner, target = scene.target, engine = scene.engine
                let clock = ContinuousClock()
                let firstImage = try #require(try await engine.renderDevice.readImage(from: target))
                try #require(firstImage.getPixel(x: 80, y: 64).red > 0.8)
                weak var obsoleteArray: (any GPUTexture)?
                weak var obsoleteField: (any GPUTexture)?
                do {
                    let initial = try #require(owner.components[TerrainSourceState.self])
                    let tile = try #require(initial.tiles.values.first)
                    let entity = try #require(app.main.getEntityByID(tile.entity))
                    let material = try #require(entity.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial)
                    obsoleteArray = material.terrainBindings?.maps.albedo.gpuTexture
                    obsoleteField = material.terrainBindings?.layerIDs.gpuTexture
                }
                try #require(obsoleteArray != nil && obsoleteField != nil)
                var source = try #require(owner.components[Terrain3DSource.self])
                for _ in 0..<3 {
                    source.reloadGeneration &+= 1
                    owner.components[Terrain3DSource.self] = source
                    let reloadDeadline = clock.now.advanced(by: .seconds(15))
                    while clock.now < reloadDeadline {
                        await app.main.runScheduler(.preUpdate)
                        if owner.components[TerrainSourceState.self]?.key == TerrainSourceKey(source),
                            owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    try #require(owner.components[TerrainSourceState.self]?.key == TerrainSourceKey(source))
                    for _ in 0..<4 { try await app.update() }
                }
                owner.components.remove(Terrain3DSource.self)
                for _ in 0..<8 { try await app.update() }
                _ = try #require(try await engine.renderDevice.readImage(from: target))
                try #require(owner.components[TerrainSourceState.self] == nil)
                #expect(obsoleteArray == nil, "The pipeline cache must release old palette GPU allocations after completed work")
                #expect(obsoleteField == nil, "Old canonical fields must not remain alive in a count-only bind-group cache")
            }

            @Test("Layer normal and ORM maps reach the shared PBR surface", arguments: [DebugView3D.normals, .roughness, .metallic])
            func terrainMaterialPBRMapPixels(view: DebugView3D) async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainMaterialGPU-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: true, pbrMaps: true, view: view)
                let target = scene.target, engine = scene.engine
                let image = try #require(try await engine.renderDevice.readImage(from: target))
                let pixel = image.getPixel(x: 80, y: 64)
                try #require(pixel.red + pixel.green + pixel.blue > 0.2)
                switch view {
                case .normals:
                    #expect(pixel.red > 0.9 && abs(pixel.green - 0.5) < 0.05 && pixel.blue < 0.6)
                case .roughness:
                    #expect(abs(pixel.red - 0.2) < 0.02 && abs(pixel.green - pixel.red) < 0.02 && abs(pixel.blue - pixel.red) < 0.02)
                case .metallic:
                    #expect(abs(pixel.red - 0.45) < 0.02 && abs(pixel.green - pixel.red) < 0.02 && abs(pixel.blue - pixel.red) < 0.02)
                default:
                    Issue.record("This fixture only selects normal, roughness and metallic views")
                }
            }

            @Test("Material AO changes real indirect lighting while preserving packed roughness and metallic")
            func terrainMaterialAOPixels() async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainMaterialAO-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: true, pbrMaps: true, view: .indirectLighting)
                let dark = try #require(try await scene.engine.renderDevice.readImage(from: scene.target)).getPixel(x: 80, y: 64).red
                try #require(dark > 0.02)
                try Image(width: 1, height: 1, color: Color(1, 0.25, 0.75, 1)).writePNG(to: directory.appendingPathComponent("orm.png"))
                var source = try #require(scene.owner.components[Terrain3DSource.self])
                source.reloadGeneration &+= 1
                scene.owner.components[Terrain3DSource.self] = source
                let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(15))
                while clock.now < deadline {
                    await scene.app.main.runScheduler(.preUpdate)
                    if scene.owner.components[TerrainSourceState.self]?.key == TerrainSourceKey(source) { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                try #require(scene.owner.components[TerrainSourceState.self]?.key == TerrainSourceKey(source))
                for _ in 0..<4 { try await scene.app.update() }
                let bright = try #require(try await scene.engine.renderDevice.readImage(from: scene.target)).getPixel(x: 80, y: 64).red
                #expect(bright > dark * 2 && bright - dark > 0.1)
            }

            @Test("Terrain PBR uniforms remain independent from enabled distance-field shadow uniforms")
            func terrainMaterialDistanceFieldPixels() async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainMaterialSDF-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: true, view: .none)
                let sun = try #require(scene.app.main.getEntities().first { $0.components[DirectionalLightComponent.self] != nil })
                var light = try #require(sun.components[DirectionalLightComponent.self])
                light.castShadows = true
                sun.components[DirectionalLightComponent.self] = light
                for _ in 0..<4 { try await scene.app.update() }
                let baseline = try #require(try await scene.engine.renderDevice.readImage(from: scene.target)).getPixel(x: 80, y: 64)
                try #require(baseline.red > 0.02)
                let texture = Texture2D(descriptor: .init(
                    width: 2,
                    height: 4,
                    pixelFormat: .r32f,
                    textureUsage: [.read],
                    textureType: .texture2D,
                    samplerDescription: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped)
                ))
                let distances = [Float](repeating: 1000, count: 8)
                unsafe distances.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        unsafe texture.replaceRegion(.init(x: 0, y: 0, width: 2, height: 4), withBytes: base, bytesPerRow: 8)
                    }
                }
                let field = try DistanceField3D(minimum: [-4, -4, -4], voxelSize: 8, counts: [2, 2, 2], texture: texture, atlasColumns: 1)
                var environment = try #require(scene.camera.components[Environment3D.self])
                environment.distanceField = .init(asset: AssetHandle(field), maxDistance: 4, maxSteps: 8, surfaceBias: 0.02, softness: 0)
                scene.camera.components[Environment3D.self] = environment
                for _ in 0..<4 { try await scene.app.update() }
                let enabled = try #require(try await scene.engine.renderDevice.readImage(from: scene.target)).getPixel(x: 80, y: 64)
                #expect(abs(enabled.red - baseline.red) < 0.01 && abs(enabled.green - baseline.green) < 0.01 && abs(enabled.blue - baseline.blue) < 0.01)
            }

            @Test("Seeded texture variation breaks periodic grids, follows local coordinates and rotates tangent normals", arguments: [false, true])
            func terrainTextureVariationPixels(enabled: Bool) async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainVariationGPU-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: false, variation: enabled)
                let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
                func difference(_ lhs: Image, _ rhs: Image, shift: Int) -> Float {
                    var total: Float = 0
                    var count: Float = 0
                    for y in stride(from: 40, to: 88, by: 4) {
                        for x in stride(from: 80, to: 168, by: 2) {
                            let a = lhs.getPixel(x: x, y: y), b = rhs.getPixel(x: x + shift, y: y)
                            total += (a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue)
                            count += 3
                        }
                    }
                    return total / count
                }
                let repetition = difference(image, image, shift: 8)
                if enabled { #expect(repetition > 0.015) } else { #expect(repetition < 0.002) }
                let offset = Vector3(10, 5, -7)
                for entity in [scene.owner, scene.camera] {
                    var transform = try #require(entity.components[Transform.self])
                    transform.position += offset
                    entity.components[Transform.self] = transform
                }
                for _ in 0..<4 { try await scene.app.update() }
                let translated = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
                #expect(difference(image, translated, shift: 0) < 0.001)
                var environment = try #require(scene.camera.components[Environment3D.self])
                environment.debugView = .normals
                scene.camera.components[Environment3D.self] = environment
                for _ in 0..<4 { try await scene.app.update() }
                let normals = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
                var minimum: Float = 1, maximum: Float = 0
                for y in stride(from: 40, to: 88, by: 4) {
                    for x in stride(from: 80, to: 168, by: 2) {
                        let red = normals.getPixel(x: x, y: y).red
                        minimum = min(minimum, red); maximum = max(maximum, red)
                    }
                }
                if enabled { #expect(minimum < 0.35 && maximum > 0.65) } else { #expect(minimum > 0.9) }
            }

            @Test("Accepted extreme scales produce filtered finite texture colors", arguments: ["macro-zero", "macro", "layer"])
            func terrainTextureVariationExtremeScales(kind: String) async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainScaleGPU-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(
                    in: directory,
                    textured: false,
                    variation: true,
                    layerScale: kind == "layer" ? .leastNonzeroMagnitude : 0.25,
                    macroScale: kind.hasPrefix("macro") ? .leastNonzeroMagnitude : 3,
                    macroStrength: kind == "macro" ? 0.5 : 0
                )
                let pixel = try #require(try await scene.engine.renderDevice.readImage(from: scene.target)).getPixel(x: 100, y: 60)
                let expected: Color
                if kind == "layer" {
                    let image = try Image(contentsOf: directory.appendingPathComponent("pattern.png"))
                    let last = try #require(try ImageMipmaps.make(from: image, colorSpace: .sRGB).last)
                    expected = last.getPixel(x: 0, y: 0)
                } else {
                    let baselineDirectory = directory.appendingPathComponent("baseline", isDirectory: true)
                    try FileManager.default.createDirectory(at: baselineDirectory, withIntermediateDirectories: true)
                    let baseline = try await makeScene(in: baselineDirectory, textured: false, variation: true, macroStrength: 0)
                    expected = try #require(try await baseline.engine.renderDevice.readImage(from: baseline.target)).getPixel(x: 100, y: 60)
                }
                try #require(expected.red + expected.green + expected.blue > 0.2)
                #expect(abs(pixel.red - expected.red) < 0.02 && abs(pixel.green - expected.green) < 0.02 && abs(pixel.blue - expected.blue) < 0.02)
            }

            @Test("Triplanar cliff mapping uses surface axes while flat normal maps preserve geometric normals", arguments: [TerrainMaterialProjection.planar, .triplanar])
            func terrainMaterialTriplanarPixels(projection: TerrainMaterialProjection) async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainProjectionGPU-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let scene = try await makeScene(in: directory, textured: false, variation: false, projection: projection, heightScale: 16, stripes: true)
                let image = try #require(try await scene.engine.renderDevice.readImage(from: scene.target))
                var values: [Float] = []
                for x in 80..<168 { values.append(image.getPixel(x: x, y: 64).red) }
                let mean = values.reduce(0, +) / Float(values.count)
                try #require(mean > 0.1)
                let variance = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
                if projection == .triplanar { #expect(variance < 0.002) } else { #expect(variance > 0.03) }
                var environment = try #require(scene.camera.components[Environment3D.self])
                environment.debugView = .normals
                scene.camera.components[Environment3D.self] = environment
                for _ in 0..<4 { try await scene.app.update() }
                let normal = try #require(try await scene.engine.renderDevice.readImage(from: scene.target)).getPixel(x: 100, y: 60)
                #expect(abs(normal.red - 0.0149) < 0.03 && abs(normal.green - 0.5) < 0.03 && abs(normal.blue - 0.3787) < 0.03)
            }

            @Test("Flat triplanar maps retain interpolated geometric normals on scaled ridges", arguments: [false, true])
            func terrainMaterialTriplanarScaledRidge(mixed: Bool) async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainRidgeGPU-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                let baselineDirectory = directory.appendingPathComponent("baseline", isDirectory: true)
                let projectedDirectory = directory.appendingPathComponent("projected", isDirectory: true)
                try FileManager.default.createDirectory(at: baselineDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: projectedDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let baseline = try await makeScene(in: baselineDirectory, textured: false, view: .normals, variation: false, stripes: true, ridged: true)
                let projected = try await makeScene(
                    in: projectedDirectory,
                    textured: false,
                    view: .normals,
                    variation: false,
                    projection: .triplanar,
                    stripes: true,
                    ridged: true,
                    mixedProjection: mixed
                )
                for scene in [baseline, projected] {
                    var owner = try #require(scene.owner.components[Transform.self])
                    owner.scale = [1, 4, 1]
                    scene.owner.components[Transform.self] = owner
                    var camera = try #require(scene.camera.components[Transform.self])
                    camera.position = [0, 0, -20]
                    scene.camera.components[Transform.self] = camera
                    for _ in 0..<4 { try await scene.app.update() }
                }
                let reference = try #require(try await baseline.engine.renderDevice.readImage(from: baseline.target))
                let actual = try #require(try await projected.engine.renderDevice.readImage(from: projected.target))
                for x in [127, 128] {
                    let a = reference.getPixel(x: x, y: 64), b = actual.getPixel(x: x, y: 64)
                    try #require(abs(a.green - 0.5) < 0.05 && a.red + a.blue > 0.02)
                    #expect(abs(a.red - b.red) < 0.015 && abs(a.green - b.green) < 0.015 && abs(a.blue - b.blue) < 0.015)
                }
            }

            @Test("Non-flat triplanar normals stay continuous across axis ties and follow reflected owner scale")
            func terrainMaterialTriplanarNormalTransforms() async throws {
                let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let directory = root.appendingPathComponent("TerrainNormalPoseGPU-" + UUID().uuidString, isDirectory: true).standardizedFileURL
                try #require(directory.deletingLastPathComponent() == root)
                let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
                let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
                try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let first = try await makeScene(
                    in: firstDirectory, textured: false, view: .normals, variation: false, projection: .triplanar, heightScale: 3.9996, crossSlope: 4
                )
                let second = try await makeScene(
                    in: secondDirectory, textured: false, view: .normals, variation: false, projection: .triplanar, heightScale: 4.0004, crossSlope: 4
                )
                for scene in [first, second] {
                    var owner = try #require(scene.owner.components[Transform.self])
                    owner.scale = [2, 3, 4]
                    scene.owner.components[Transform.self] = owner
                    var camera = try #require(scene.camera.components[Transform.self])
                    camera.position = [0, 0, -40]
                    scene.camera.components[Transform.self] = camera
                    for _ in 0..<4 { try await scene.app.update() }
                }
                let a = try #require(try await first.engine.renderDevice.readImage(from: first.target)).getPixel(x: 100, y: 64)
                let b = try #require(try await second.engine.renderDevice.readImage(from: second.target)).getPixel(x: 100, y: 64)
                try #require(a.red + a.green + a.blue > 0.2 && b.red + b.green + b.blue > 0.2)
                #expect(abs(a.red - b.red) < 0.008 && abs(a.green - b.green) < 0.008 && abs(a.blue - b.blue) < 0.008)
                var reflected = try #require(second.owner.components[Transform.self])
                reflected.scale = [-2, 3, 4]
                second.owner.components[Transform.self] = reflected
                for _ in 0..<4 { try await second.app.update() }
                let mirror = try #require(try await second.engine.renderDevice.readImage(from: second.target)).getPixel(x: 100, y: 64)
                #expect(abs(mirror.red - (1 - b.red)) < 0.012 && abs(mirror.green - b.green) < 0.012 && abs(mirror.blue - b.blue) < 0.012)
            }
        }
    }
#endif
