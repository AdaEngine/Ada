#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaAssets
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// Original deterministic fixtures under the repository license, without external assets.
/// These isolate workload shape; they are not evidence about a shipped game's asset distribution.
@MainActor
enum MeshletBaselineFixtures {
    enum Workload: String, CaseIterable {
        case partial, occluded, allVisible, instances, smallParts, garden
    }

    struct Scene {
        let app: AppWorlds
        let device: RenderDevice
        let target: RenderTexture
        let camera: Entity
    }

    static func empty(size: SizeInt, cameraPosition: Vector3 = [0, 0, -10], shadows: Bool = false) async throws -> Scene {
        let backend: RenderBackendType = GoldenFrame.activeBackend == .saga ? .saga : .metal
        unsafe RenderEngine.configurations.preferredBackend = backend
        try RenderEngine.setupRenderEngine()
        let engine = try #require(unsafe RenderEngine.shared)
        try #require(engine.type == backend)
        let device = engine.renderDevice
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
        let target = RenderTexture(size: size, scaleFactor: 1, format: .bgra8)
        var environment = Environment3D(antiAliasing: .none)
        environment.skybox.isEnabled = false
        environment.shadows.isEnabled = shadows
        environment.shadowCascadeCount = 3
        environment.ambientOcclusion.isEnabled = false
        environment.screenSpaceReflection.isEnabled = false
        let camera = app.main.spawn("Camera", bundle: Camera3D(
            camera: Camera(renderTarget: target),
            transform: Transform(position: cameraPosition), environment: environment
        ))
        let lighting = app.main.spawn("Lighting") { Transform() }
        lighting.addChild(app.main.spawn("Sun") {
            DirectionalLightComponent(intensity: 3, castShadows: shadows)
            Transform(rotation: Quat.euler([-0.4, 0.5, 0]))
        })
        return Scene(app: app, device: device, target: target, camera: camera)
    }

    static func make(_ workload: Workload, size: SizeInt, subdivisions: Int) async throws -> Scene {
        let scene = try await empty(size: size, cameraPosition: [0, 0, workload == .allVisible ? -40 : -10])
        let app = scene.app, device = scene.device
        let geometry = app.main.spawn("Environment") { Transform() }
        let material = PBRMaterial()
        material.baseColorFactor = [0.8, 0.4, 0.2, 1]
        material.roughnessFactor = 0.8
        material.metallicFactor = 0
        func add(_ name: String, mesh: Mesh, position: Vector3, material: PBRMaterial) {
            geometry.addChild(app.main.spawn(name) {
                Mesh3DComponent(mesh: mesh, materials: [material])
                Transform(position: position)
            })
        }
        switch workload {
        case .partial, .occluded, .allVisible:
            let mesh = Mesh.generate(from: [surface(subdivisions: subdivisions)], renderDevice: device)
            add("Large surface", mesh: mesh, position: [workload == .partial ? 32 : 0, 0, 20], material: material)
            if workload == .occluded {
                let wall = PBRMaterial()
                wall.baseColorFactor = [0.15, 0.5, 0.3, 1]
                add("Half-width occluder", mesh: .generateCube(size: [12, 20, 0.5], renderDevice: device), position: [-6, 0, 4], material: wall)
            }
        case .instances:
            let shared = Mesh.generateSphere(radius: 0.2, segments: 16, rings: 12, renderDevice: device)
            for row in 0..<40 {
                for column in 0..<40 {
                    add("Instance \(row)-\(column)", mesh: shared, position: [Float(column) * 0.45 - 8.8, Float(row) * 0.45 - 8.8, 20], material: material)
                }
            }
        case .smallParts:
            // Independent buffers deliberately prevent batching, unlike the repeated-instance control.
            for row in 0..<16 {
                for column in 0..<16 {
                    add("Small part \(row)-\(column)", mesh: .generateCube(size: [0.4, 0.4, 0.4], renderDevice: device),
                        position: [Float(column) - 7.5, Float(row) - 7.5, 20], material: material)
                }
            }
        case .garden:
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/SkeletalGardenAssets")
            for (index, name) in ["Courtyard", "Bench", "Lantern", "Pedestal"].enumerated() {
                let model = try #require(try await AssetsManager.load(ModelAsset3D.self,
                    at: directory.appendingPathComponent(name + ".glb").path).asset)
                let root = model.instantiate(in: app.main)
                root.components[Transform.self] = Transform(position: [Float(index) * 2 - 3, -1, 6])
                geometry.addChild(root)
            }
        }
        return scene
    }

    private static func surface(subdivisions: Int) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "Meshlet baseline surface v1")
        var positions: [Vector3] = [], normals: [Vector3] = []
        for row in 0...subdivisions {
            for column in 0...subdivisions {
                positions.append([40 * Float(column) / Float(subdivisions) - 20, 16 * Float(row) / Float(subdivisions) - 8, 0])
                normals.append([0, 0, -1])
            }
        }
        var indices: [UInt32] = []
        for row in 0..<subdivisions {
            for column in 0..<subdivisions {
                let a = UInt32(row * (subdivisions + 1) + column), b = a + UInt32(subdivisions + 1)
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.indicies = indices
        return descriptor
    }
}
#endif
