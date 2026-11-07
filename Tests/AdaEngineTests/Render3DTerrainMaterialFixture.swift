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

    extension Render3DGPUTests.TerrainMaterials {
        func makeScene(
            in directory: URL,
            textured: Bool,
            pbrMaps: Bool = false,
            view: DebugView3D = .albedo,
            variation: Bool? = nil,
            layerScale: Float = 0.25,
            macroScale: Float = 3,
            macroStrength: Float = 0.05,
            projection: TerrainMaterialProjection = .planar,
            heightScale: Float = 1,
            stripes: Bool = false,
            ridged: Bool = false,
            mixedProjection: Bool = false,
            crossSlope: Float = 0,
            heightBlend: Bool = false,
            missingHeight: Bool = false,
            heightFade: String? = nil,
            surfaceMode: String? = nil
        ) async throws -> (app: AppWorlds, owner: Entity, camera: Entity, target: RenderTexture, engine: RenderEngine) {
            let file = try await makeTerrain(
                in: directory,
                textured: textured,
                pbrMaps: pbrMaps,
                variation: variation,
                layerScale: layerScale,
                macroScale: macroScale,
                macroStrength: macroStrength,
                projection: projection,
                heightScale: heightScale,
                stripes: stripes,
                ridged: ridged,
                mixedProjection: mixedProjection,
                crossSlope: crossSlope,
                heightBlend: heightBlend,
                missingHeight: missingHeight,
                heightFade: heightFade,
                surfaceMode: surfaceMode
            )
            let requested: RenderBackendType = GoldenFrame.activeBackend == .webgpu ? .webgpu : .metal
            unsafe RenderEngine.configurations.preferredBackend = requested
            try RenderEngine.setupRenderEngine()
            let engine = try #require(unsafe RenderEngine.shared)
            try #require(engine.type == requested)
            let app = AppWorlds(main: World())
            app.insertResource(OffscreenRenderWorld())
                .insertResource(PrimaryWindowId(windowId: RID()))
                .addPlugin(MainSchedulerPlugin())
                .addPlugin(TransformPlugin())
                .addPlugin(RenderWorldPlugin())
                .addPlugin(CameraPlugin())
                .addPlugin(AssetsPlugin(filePath: #filePath))
                .addPlugin(VisibilityPlugin())
                .addPlugin(ScenePlugin())
                .addPlugin(Core3DPlugin())
            try await app.build()
            let target = RenderTexture(size: [256, 128], scaleFactor: 1, format: .bgra8)
            var camera = Camera(renderTarget: target)
            camera.projection = .orthographic(.init(near: 0.1, far: 50, scale: 32))
            camera.backgroundColor = .black
            var environment = Environment3D(ambientOcclusion: .init(isEnabled: false), antiAliasing: .none)
            environment.debugView = view
            environment.skybox.isEnabled = false
            environment.screenSpaceReflection.isEnabled = false
            environment.shadows.isEnabled = false
            environment.contactShadows.isEnabled = false
            environment.screenSpaceGI.isEnabled = false
            environment.fog.isEnabled = false
            environment.postProcess.autoExposure.isEnabled = false
            environment.postProcess.bloom.isEnabled = false
            let cameraEntity = app.main.spawn(
                "Material test camera",
                bundle: Camera3D(
                    camera: camera,
                    transform: Transform(position: [0, 0, heightScale + crossSlope > 1 ? -(heightScale + crossSlope + 6) : -6]),
                    environment: environment
                )
            )
            var configuredCamera = try #require(cameraEntity.components[Camera.self])
            configuredCamera.projection = camera.projection
            cameraEntity.components[Camera.self] = configuredCamera
            app.main.spawn("Environment light") {
                DirectionalLightComponent(radiance: [1, 1, 1], intensity: 1, castShadows: false)
                Transform()
            }
            let pose = Quat(axis: [1, 0, 0], angle: -Float.pi / 2)
            try #require((Transform3D(quat: pose) * Vector4(0, 1, 0, 0)).z < -0.99)
            let owner = app.main.spawn("Authored terrain") {
                Transform(rotation: pose)
                Terrain3DSource(source: file.path, color: .one, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            while clock.now < deadline {
                await app.main.runScheduler(.preUpdate)
                if owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
            for _ in 0..<4 { try await app.update() }
            return (app, owner, cameraEntity, target, engine)
        }

        func waitForMaterialEdit(_ app: AppWorlds, owner: Entity, id: UUID) async throws {
            let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(15))
            while clock.now < deadline {
                await app.main.runScheduler(.preUpdate)
                if let status = owner.components[Terrain3DEditStatus.self], status.id == id, status.phase != .pending {
                    return
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(false, "Terrain material edit did not complete before its bounded deadline")
        }

        func materialBuffers(_ owner: Entity) throws -> [TerrainTileCoordinate: ObjectIdentifier] {
            var result: [TerrainTileCoordinate: ObjectIdentifier] = [:]
            for child in owner.children {
                guard let tile = child.components[TerrainTile3DComponent.self] else { continue }
                let part = try #require(child.components[Mesh3DComponent.self]?.mesh.models.first?.parts.first)
                result[tile.coordinate] = ObjectIdentifier(part.vertexBuffer)
            }
            return result
        }

        private func makeTerrain(
            in directory: URL,
            textured: Bool,
            pbrMaps: Bool = false,
            variation: Bool? = nil,
            layerScale: Float = 0.25,
            macroScale: Float = 3,
            macroStrength: Float = 0.05,
            projection: TerrainMaterialProjection = .planar,
            heightScale: Float = 1,
            stripes: Bool = false,
            ridged: Bool = false,
            mixedProjection: Bool = false,
            crossSlope: Float = 0,
            heightBlend: Bool = false,
            missingHeight: Bool = false,
            heightFade: String? = nil,
            surfaceMode: String? = nil
        ) async throws -> URL {
            if textured {
                try Image(width: 1, height: 1, color: .red).writePNG(to: directory.appendingPathComponent("low.png"))
                try Image(width: 1, height: 1, color: .blue).writePNG(to: directory.appendingPathComponent("high.png"))
            }
            if heightBlend && !missingHeight {
                try Image(width: 1, height: 1, color: .black).writePNG(to: directory.appendingPathComponent("low-height.png"))
                try Image(width: 1, height: 1, color: .white).writePNG(to: directory.appendingPathComponent("high-height.png"))
            }
            if pbrMaps {
                try Image(width: 1, height: 1, color: Color(1, 0.5, 0.5, 1)).writePNG(to: directory.appendingPathComponent("normal.png"))
                try Image(width: 1, height: 1, color: Color(0.2, 0.25, 0.75, 1)).writePNG(to: directory.appendingPathComponent("orm.png"))
            }
            if variation != nil {
                var bytes = Data(count: 8 * 8 * 4)
                for y in 0..<8 {
                    for x in 0..<8 {
                        let rgb: [UInt8] = x < 3 ? [255, 30, 20] : (stripes || y >= 5 ? [40, 30, 255] : [20, 255, 40])
                        for channel in 0..<3 { bytes[(y * 8 + x) * 4 + channel] = rgb[channel] }
                        bytes[(y * 8 + x) * 4 + 3] = 255
                    }
                }
                try Image(width: 8, height: 8, data: bytes).writePNG(to: directory.appendingPathComponent("pattern.png"))
                try Image(width: 1, height: 1, color: stripes ? Color(0.5, 0.5, 1, 1) : Color(1, 0.5, 0.5, 1)).writePNG(to: directory.appendingPathComponent("variation-normal.png"))
            }
            var terrain = Terrain3D(resolution: 129, size: 4)
            for z in 0..<terrain.resolution {
                for x in 0..<terrain.resolution {
                    let localX = Float(x) / 32 - 2
                    terrain.heights[z * terrain.resolution + x] = ridged ? max(0, localX) : Float(x) / 128 * heightScale + Float(z) / 128 * crossSlope
                }
            }
            let storage = try TerrainHeightStorage(importing: terrain)
            var regions: [TerrainRegionAsset] = []
            for coordinate in storage.resourceCoordinates {
                if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
            }
            var palette = TerrainMaterialPalette(
                layers: [
                    .init(
                        id: 7,
                        name: "Low red",
                        albedoPath: textured ? "low.png" : nil,
                        blendHeightPath: heightBlend ? "low-height.png" : nil,
                        tint: textured ? .one : [1, 0, 0, 1]
                    ),
                    .init(
                        id: 12,
                        name: "High blue",
                        albedoPath: textured ? "high.png" : nil,
                        blendHeightPath: heightBlend ? "high-height.png" : nil,
                        tint: textured ? .one : [0, 0, 1, 1]
                    ),
                ],
                fallbackLayerID: 7,
                rules: [
                    .init(layerID: 7, height: .init(minimum: -100, maximum: 0.4, transition: 0.2)),
                    .init(layerID: 12, height: .init(minimum: 0.6, maximum: 100, transition: 0.2)),
                ]
            )
            if let heightFade {
                try Image(width: 1, height: 1, color: .green).writePNG(to: directory.appendingPathComponent("third.png"))
                try Image(width: 1, height: 1, color: .black).writePNG(to: directory.appendingPathComponent("base-height.png"))
                try Image(width: 1, height: 1, color: heightFade == "high" ? .white : Color(0.5, 0.5, 0.5, 1))
                    .writePNG(to: directory.appendingPathComponent("third-height.png"))
                palette = TerrainMaterialPalette(
                    layers: [
                        .init(id: 7, name: "Red", albedoPath: "low.png", blendHeightPath: heightFade == "high" ? "base-height.png" : nil),
                        .init(id: 12, name: "Blue", albedoPath: "high.png", blendHeightPath: heightFade == "high" ? "base-height.png" : nil),
                        .init(id: 23, name: "Fading green", albedoPath: "third.png", blendHeightPath: "third-height.png"),
                    ],
                    fallbackLayerID: 7,
                    rules: [
                        .init(layerID: 7, weight: 0.6),
                        .init(layerID: 12, weight: 0.4),
                        .init(layerID: 23, weight: 0.004, height: .init(minimum: -100, maximum: 0.4, transition: 0.2)),
                    ]
                )
            }
            if pbrMaps {
                palette = TerrainMaterialPalette(
                    layers: [.init(id: 31, name: "Mapped PBR", normalPath: "normal.png", ormPath: "orm.png", roughness: 0.8, metallic: 0.6)],
                    fallbackLayerID: 31
                )
            }
            if let variation {
                palette = TerrainMaterialPalette(
                    layers: [
                        .init(
                            id: 31,
                            name: "Asymmetric texture",
                            albedoPath: "pattern.png",
                            normalPath: "variation-normal.png",
                            scale: layerScale,
                            projection: projection,
                            variation: .init(isEnabled: variation, seed: 0xF123_4567_89AB_CDEF, macroStrength: macroStrength, macroScale: macroScale)
                        )
                    ],
                    fallbackLayerID: 31
                )
            }
            if mixedProjection, let first = palette.layers.first {
                let planar = TerrainLayerReference(
                    id: 42, name: "Planar mix", albedoPath: first.albedoPath, normalPath: first.normalPath, scale: first.scale
                )
                palette = TerrainMaterialPalette(
                    layers: [first, planar], fallbackLayerID: first.id, rules: [.init(layerID: first.id), .init(layerID: 42)]
                )
            }
            if let surfaceMode {
                var painted: [TerrainRegionSurfaceSample] = []
                for z in 32...96 {
                    for x in 32...96 {
                        if surfaceMode == "layer" {
                            painted.append(.init(x: UInt8(x), z: UInt8(z), layerIDs: [12, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1))
                        } else {
                            painted.append(.init(
                                x: UInt8(x),
                                z: UInt8(z),
                                tint: [0.25, 0.5, 0.75, 1],
                                tintStrength: 0.5,
                                roughness: 0.2,
                                roughnessStrength: 0.5
                            ))
                        }
                    }
                }
                regions = regions.map {
                    TerrainRegionAsset(x: $0.x, z: $0.z, tiles: $0.tiles, pages: $0.pages, surface: $0.x == 0 && $0.z == 0 ? painted : [])
                }
                if surfaceMode != "layer" {
                    palette = TerrainMaterialPalette(layers: [.init(id: 7, name: "White base", roughness: 0.8)], fallbackLayerID: 7)
                }
            }
            let layout = TerrainManifestAsset(spacing: storage.spacing, originX: storage.origin.x, originZ: storage.origin.y, materials: palette)
            let file = directory.appendingPathComponent("world.aterrain")
            _ = try await AssetsManager.saveTerrainRegions(regions, manifest: layout, at: file.path)
            return file
        }
    }
#endif
