#if os(macOS)
import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaEngine

extension Render3DGPUTests {
    @Suite("SceneView camera navigation on GPU")
    @MainActor
    struct SceneNavigation {
        private static func scene(name: String, color: Vector3, device: RenderDevice) -> Scene {
            let scene = Scene(name: name)
            var environment = Environment3D()
            environment.skybox.isEnabled = false
            environment.ambientOcclusion.isEnabled = false
            environment.screenSpaceReflection.isEnabled = false
            var camera = Camera()
            camera.backgroundColor = .black
            scene.world.spawn(name, bundle: Camera3D(camera: camera, environment: environment))
            let material = PBRMaterial()
            material.baseColorFactor = [0, 0, 0, 1]
            material.emissiveFactor = color
            material.emissiveStrength = 4
            scene.world.spawn("Emissive geometry") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: .one, renderDevice: device), materials: [material])
                Transform(position: [0, 0, 2])
            }
            return scene
        }

        @Test(.enabled(if: GoldenFrame.activeBackend == .metal))
        func replacingAndReloading3DCamerasKeepsCompletingNewFrames() async throws {
            unsafe RenderEngine.configurations.preferredBackend = .metal
            try RenderEngine.setupRenderEngine()
            try #require(unsafe RenderEngine.shared.type == .metal)
            let device = unsafe RenderEngine.shared.renderDevice
            let runtime = OffscreenSceneRuntime(label: "navigation-\(UUID())", size: [96, 96], useSceneCameras: true) { app in
                app.addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(CameraPlugin())
                    .addPlugin(AssetsPlugin(filePath: #filePath)).addPlugin(VisibilityPlugin())
                    .addPlugin(ScenePlugin()).addPlugin(Core3DPlugin())
            }
            defer { runtime.stop() }
            try await runtime.start()
            let source = runtime.frameSource
            let world = try #require(source.world)
            let navigator = try #require(world.getResource(SceneNavigator.self))
            navigator.installInitialScene(Self.scene(name: "Red camera", color: [1, 0, 0], device: device)) {
                Self.scene(name: "Red camera", color: [1, 0, 0], device: device)
            }
            navigator.setSceneLoader { path in
                await MainActor.run {
                    Self.scene(name: path, color: path == "Blue camera" ? [0, 0, 1] : [1, 0, 0], device: device)
                }
            }
            let first: SceneViewCapturedFrame
            do {
                first = try await source.captureFrame(after: source.frameSequence, timeout: .seconds(5))
            } catch {
                Issue.record("Initial 3D frame unavailable: \(error); completed=\(source.frameSequence), cameras=\(source.activeCameraNames)")
                return
            }
            #expect(first.image.getPixel(x: 48, y: 48).red > 0.5)

            for name in ["Blue camera", "Red camera", "Red camera"] {
                let oldCamera = try #require(world.getEntities().first { $0.components[Camera.self] != nil })
                if name == "Red camera", navigator.currentScenePath == name {
                    #expect(navigator.requestReloadScene())
                } else {
                    navigator.requestReplaceScene(with: name)
                }
                let clock = ContinuousClock()
                let deadline = clock.now + .seconds(3)
                while world.getEntityByID(oldCamera.id) != nil, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try #require(world.getEntityByID(oldCamera.id) == nil)
                #expect(source.activeCameraNames == [name])
                // Require sustained progress beyond any old GPU frames already in flight at the transition.
                var sequence = source.frameSequence
                for _ in 0..<3 {
                    let frame: SceneViewCapturedFrame
                    do {
                        frame = try await source.captureFrame(after: sequence, cameraName: name, timeout: .seconds(2))
                    } catch {
                        Issue.record("No frame after replacement with \(name): \(error); completed=\(source.frameSequence), previous=\(sequence)")
                        return
                    }
                    sequence = frame.sequence
                    let center = frame.image.getPixel(x: 48, y: 48)
                    if name == "Blue camera" { #expect(center.blue > 0.5 && center.red < 0.1) }
                    else { #expect(center.red > 0.5 && center.blue < 0.1) }
                }
            }
        }
    }
}
#endif
