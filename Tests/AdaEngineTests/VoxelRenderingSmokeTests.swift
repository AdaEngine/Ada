#if os(macOS)
@_spi(Internal) import AdaApp
import AdaEngine
@_spi(Internal) import AdaRender
import Foundation
import Testing

/// Renders imported MagicaVoxel models through the real Metal 3D pipeline and writes PNGs for inspection.
///
/// Run alone: `ADAENGINE_VOXEL_METAL_SMOKE=1 swift test --filter VoxelRenderingSmokeTests`.
/// Other integration suites initialize the process-wide engine as headless.
@Suite("Voxel Metal scene", .serialized)
@MainActor
struct VoxelRenderingSmokeTests {
    private static let outputDirectory = ProcessInfo.processInfo.environment["ADAENGINE_VOXEL_SMOKE_OUTPUT"] ?? "/tmp"

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AdaAssetsTests/Fixtures/vox/\(name).vox")
    }

    private struct Scene {
        let app: AppWorlds
        let device: RenderDevice
        let target: RenderTexture

        func render(frames: Int = 1) async throws -> Image {
            for _ in 0..<frames {
                try await app.update()
            }
            return try #require(try await device.readImage(from: target))
        }
    }

    private static func makeScene() async throws -> Scene {
        unsafe RenderEngine.configurations.preferredBackend = .saga
        try RenderEngine.setupRenderEngine()
        try #require(unsafe RenderEngine.shared.type == .saga)
        let device = unsafe RenderEngine.shared.renderDevice
        let app = AppWorlds(main: World())
        app.insertResource(OffscreenRenderWorld())
            .insertResource(PrimaryWindowId(windowId: RID()))
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(TransformPlugin())
            .addPlugin(RenderWorldPlugin())
            .addPlugin(EventsPlugin())
            .addPlugin(CameraPlugin())
            .addPlugin(AssetsPlugin(filePath: #filePath))
            .addPlugin(VisibilityPlugin())
            .addPlugin(ScenePlugin())
            .addPlugin(Core3DPlugin())
            .addPlugin(Physics3DPlugin())
        try await app.build()

        let target = RenderTexture(size: SizeInt(width: 640, height: 480), scaleFactor: 1, format: .bgra8)
        var environment = Environment3D(ambientOcclusion: .init(isEnabled: true), antiAliasing: .fxaa)
        environment.skybox.isEnabled = false
        environment.screenSpaceReflection.isEnabled = false
        var camera = Camera(renderTarget: target)
        camera.backgroundColor = Color(0.55, 0.7, 0.9, 1)
        app.main.spawn(
            "Camera",
            bundle: Camera3D(
                camera: camera,
                transform: Transform(rotation: Quat(axis: [1, 0, 0], angle: 0.45), position: [0, 1.7, -2.6]),
                environment: environment
            )
        )
        app.main.spawn("Sun") {
            DirectionalLightComponent(radiance: [1, 0.95, 0.85], intensity: 3, castShadows: true)
            Transform(rotation: Quat.euler([-0.9, 0.6, 0]))
        }
        return Scene(app: app, device: device, target: target)
    }

    private static func nonBackgroundPixels(in image: Image) -> Int {
        var count = 0
        for y in stride(from: 0, to: 480, by: 4) {
            for x in stride(from: 0, to: 640, by: 4) {
                let offset = (y * 640 + x) * 4
                // Background is (0.55, 0.7, 0.9) -> BGRA (230, 178, 140) before tone mapping; compare against the corner pixel.
                let corner = 0
                let differs = (0..<3).contains { abs(Int(image.data[offset + $0]) - Int(image.data[corner + $0])) > 24 }
                if differs {
                    count += 1
                }
            }
        }
        return count
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VOXEL_METAL_SMOKE"] == "1"))
    func rendersImportedCastle() async throws {
        let scene = try await Self.makeScene()
        let model = try #require(await AssetsManager.load(ModelAsset3D.self, at: Self.fixtureURL("castle").path).asset)
        let root = model.instantiate(in: scene.app.main)
        root.components[Transform.self] = Transform(position: [0, 0.6, 0])

        let image = try await scene.render(frames: 4)
        try image.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-voxel-castle.png"))
        #expect(Self.nonBackgroundPixels(in: image) > 1500)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VOXEL_METAL_SMOKE"] == "1"))
    func rendersImportedRobotWithMergedStaticParts() async throws {
        let scene = try await Self.makeScene()
        let file = try await VOXLoader().load(url: Self.fixtureURL("robot"))
        let model = ModelAsset3D(voxelFile: file, options: VoxelImportOptions(mergeStatic: true))
        let root = model.instantiate(in: scene.app.main)
        root.components[Transform.self] = Transform(position: [0, 0.8, 0])

        let image = try await scene.render(frames: 4)
        try image.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-voxel-robot.png"))
        #expect(Self.nonBackgroundPixels(in: image) > 600)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VOXEL_METAL_SMOKE"] == "1"))
    func rendersRobotAnimationFrames() async throws {
        let scene = try await Self.makeScene()
        let file = try await VOXLoader().load(url: Self.fixtureURL("robot"))
        let model = ModelAsset3D(voxelFile: file, options: VoxelImportOptions(mergeStatic: true))
        let root = model.instantiate(in: scene.app.main)
        root.components[Transform.self] = Transform(position: [0, 0.1, 0])

        var frames: [Image] = []
        for (name, frame) in [("start", 0.0), ("end", 10.0)] {
            var playback = try #require(root.components[VoxelAnimationPlayback3DComponent.self])
            playback.isPlaying = false
            playback.time = frame / playback.framesPerSecond
            root.components[VoxelAnimationPlayback3DComponent.self] = playback
            let image = try await scene.render(frames: 3)
            try image.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-voxel-robot-\(name).png"))
            frames.append(image)
        }
        // The arm moved, so the two renders differ.
        #expect(frames[0].data != frames[1].data)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VOXEL_METAL_SMOKE"] == "1"))
    func rendersDynamicWorldBeforeAndAfterEdit() async throws {
        let scene = try await Self.makeScene()
        let palette = VOXPalette(
            colors: [
                VOXColor(red: 90, green: 170, blue: 70),
                VOXColor(red: 140, green: 100, blue: 60),
                VOXColor(red: 130, green: 130, blue: 140),
                VOXColor(red: 235, green: 235, blue: 240)
            ] + [VOXColor](repeating: VOXColor(red: 0, green: 0, blue: 0), count: 252)
        )
        let component = VoxelWorld3DComponent(palette: palette, voxelSize: 0.05, meshingBudget: 32)
        let owner = scene.app.main.spawn("World") {
            component
            Transform(position: [-2.4, 0, 0])
        }
        _ = owner

        // Rolling hills over 96 x 96 voxels: grass on top, soil below, stone deep down, snow on peaks.
        for x in 0..<96 {
            for z in 0..<96 {
                let ridge: Double = Foundation.sin(Double(x) / 11)
                let hollow: Double = Foundation.cos(Double(z) / 9)
                let wave: Double = 8 * ridge + 6 * hollow
                let height: Int = 20 + Int(wave)
                for y in 0..<height {
                    var color: UInt8 = 3
                    if y == height - 1 {
                        color = height > 30 ? 4 : 1
                    } else if y > height - 5 {
                        color = 2
                    }
                    component.storage.setVoxel(x: x, y: y, z: z, color: color)
                }
            }
        }

        let before = try await scene.render(frames: 12)
        try before.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-voxel-world-before.png"))
        #expect(!component.storage.hasDirtyChunks)

        // Carve a crater: clear every voxel within 14 voxels of a point on the surface.
        for x in 30..<66 {
            for y in 5..<50 {
                for z in 30..<66 {
                    let dx = x - 48, dy = y - 28, dz = z - 48
                    if dx * dx + dy * dy + dz * dz <= 14 * 14 {
                        component.storage.setVoxel(x: x, y: y, z: z, color: 0)
                    }
                }
            }
        }
        let after = try await scene.render(frames: 12)
        try after.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-voxel-world-after.png"))
        #expect(before.data != after.data)
        #expect(Self.nonBackgroundPixels(in: before) > 3000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VOXEL_METAL_SMOKE"] == "1"))
    func rendersDetachedIslandFalling() async throws {
        let scene = try await Self.makeScene()
        let voxelSize: Float = 0.1
        let palette = VOXPalette(
            colors: [
                VOXColor(red: 120, green: 170, blue: 90),
                VOXColor(red: 210, green: 70, blue: 60),
                VOXColor(red: 140, green: 140, blue: 150)
            ] + [VOXColor](repeating: VOXColor(red: 0, green: 0, blue: 0), count: 253)
        )
        let component = VoxelWorld3DComponent(palette: palette, voxelSize: voxelSize, meshingBudget: 32, generatesColliders: true)
        scene.app.main.spawn("World") {
            component
            Transform(position: [-1.2, 0, 0.4])
        }
        let storage = component.storage
        storage.fill(from: SIMD3(0, 0, 0), to: SIMD3(23, 3, 23), color: 1)
        storage.fill(from: SIMD3(11, 4, 11), to: SIMD3(12, 15, 12), color: 3)
        storage.fill(from: SIMD3(8, 16, 8), to: SIMD3(15, 23, 15), color: 2)

        let before = try await scene.render(frames: 8)
        try before.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-voxel-island-before.png"))

        // Remove the whole pillar so the red block is cut off and falls flat onto the platform.
        let cut = (4...15).flatMap { y in (11...12).flatMap { z in (11...12).map { x in SIMD3(x, y, z) } } }
        for point in cut {
            storage.setVoxel(x: point.x, y: point.y, z: point.z, color: 0)
        }
        let islands = storage.detachFloatingIslands(around: cut, isAnchored: { $0.y <= 3 })
        let island = try #require(islands.first)
        let body = try #require(
            island.spawnBody(
                in: scene.app.main,
                palette: palette,
                voxelSize: voxelSize,
                worldTransform: Transform(position: [-1.2, 0, 0.4]).matrix
            )
        )
        _ = body

        _ = try await scene.render(frames: 6)
        await scene.app.main.runScheduler(.physicsSync)
        scene.app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        for _ in 0..<150 {
            await scene.app.main.runScheduler(.physicsStep)
            await scene.app.main.runScheduler(.physicsWriteback)
        }
        let after = try await scene.render(frames: 6)
        try after.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-voxel-island-after.png"))
        #expect(before.data != after.data)
        // The block fell flat onto the platform (top at 0.4) and rests on it: center = 0.4 + half of 0.8.
        let endHeight = try #require(body.components[Transform.self]).position.y
        #expect(abs(endHeight - 0.8) < 0.15)
    }

    /// Bounds of a model in its own space, from the meshes of the default scene.
    private static func bounds(of model: ModelAsset3D) -> (min: Vector3, max: Vector3)? {
        var lower = Vector3(Float.greatestFiniteMagnitude)
        var upper = Vector3(-Float.greatestFiniteMagnitude)
        var found = false
        func visit(_ index: Int, parent: Transform3D) {
            let node = model.nodes[index]
            let world = parent * node.transform
            if let meshIndex = node.meshIndex {
                let box = model.meshes[meshIndex].bounds
                for x in [box.min.x, box.max.x] {
                    for y in [box.min.y, box.max.y] {
                        for z in [box.min.z, box.max.z] {
                            let point = (world * Vector4(x, y, z, 1)).xyz
                            lower = min(lower, point)
                            upper = max(upper, point)
                            found = true
                        }
                    }
                }
            }
            for child in node.children {
                visit(child, parent: world)
            }
        }
        for root in model.scenes.first ?? [] {
            visit(root, parent: .identity)
        }
        return found ? (lower, upper) : nil
    }

    /// Renders real MagicaVoxel files. Set `ADAENGINE_VOX_SAMPLES` to a directory of `.vox` files; files are matched by name.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VOXEL_METAL_SMOKE"] == "1" && ProcessInfo.processInfo.environment["ADAENGINE_VOX_SAMPLES"] != nil))
    func rendersRealMagicaVoxelSamples() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ADAENGINE_VOX_SAMPLES"]))
        let names = ProcessInfo.processInfo.environment["ADAENGINE_VOX_RENDER"]?.split(separator: ",").map(String.init)
            ?? ["castle", "chr_knight", "teapot", "doom", "cars", "room", "monu1", "menger", "anim/T-Rex", "anim/Gomez", "anim/deer"]

        for name in names {
            let scene = try await Self.makeScene()
            let url = directory.appendingPathComponent("\(name).vox")
            let clock = ContinuousClock()
            let started = clock.now
            let file = try await VOXLoader().load(url: url)
            let parsed = clock.now
            let model = ModelAsset3D(voxelFile: file)
            let imported = clock.now
            let triangles = model.meshes.reduce(0) { total, mesh in
                total + mesh.models.reduce(0) { $0 + $1.parts.reduce(0) { $0 + $1.indexCount / 3 } }
            }
            print("VOXRENDER \(name): parse \(parsed - started), import \(imported - parsed), meshes \(model.meshes.count), triangles \(triangles), timeline \(String(describing: model.voxelTimeline))")

            let box = try #require(Self.bounds(of: model), Comment(rawValue: name))
            let size = box.max - box.min
            let extent = max(size.x, max(size.y, size.z))
            let scale = extent > 0 ? 1.6 / extent : 1
            let center = (box.min + box.max) * 0.5
            let root = model.instantiate(in: scene.app.main)
            root.components[Transform.self] = Transform(scale: Vector3(scale), position: Vector3(-center.x * scale, 0.9 - center.y * scale, -center.z * scale))

            let safeName = name.replacingOccurrences(of: "/", with: "-")
            if var playback = root.components[VoxelAnimationPlayback3DComponent.self] {
                playback.isPlaying = false
                for (label, fraction) in [("a", 0.0), ("b", 0.5)] {
                    playback.time = fraction * Double(playback.frameCount) / playback.framesPerSecond
                    root.components[VoxelAnimationPlayback3DComponent.self] = playback
                    let image = try await scene.render(frames: 4)
                    try image.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-vox-\(safeName)-\(label).png"))
                    #expect(Self.nonBackgroundPixels(in: image) > 300, Comment(rawValue: "\(name) \(label)"))
                }
            } else {
                let image = try await scene.render(frames: 4)
                try image.writePNG(to: URL(fileURLWithPath: "\(Self.outputDirectory)/adaengine-vox-\(safeName).png"))
                #expect(Self.nonBackgroundPixels(in: image) > 300, Comment(rawValue: name))
            }
        }
    }
}
#endif
