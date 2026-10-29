#if os(macOS) || os(Windows) || os(Linux)
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing
@testable import AdaCorePipelines

@Suite("3D camera optics settings")
struct Render3DCameraEffectsSettingsTests {
    @Test func weatherLensIsIndependentPauseSafeAndBackwardsCompatible() throws {
        let old = try JSONDecoder().decode(Lens3D.self, from: Data("{}".utf8))
        #expect(old.rainAmount == 0 && old.rainTime == 0 && !old.changesImage)
        let wet = Lens3D(rainAmount: 0.8, rainTime: 7)
        #expect(wet.changesImage && !wet.isEnabled)
        #expect(try JSONDecoder().decode(Lens3D.self, from: JSONEncoder().encode(wet)) == wet)
        let invalid = Lens3D(rainAmount: .infinity, rainTime: .nan).sanitized
        #expect(invalid.rainAmount == 0 && invalid.rainTime == 0)
    }
    @Test func legacyScenesKeepTheirImage() throws {
        let settings = try JSONDecoder().decode(PostProcess3D.self, from: Data(#"{"exposureEV":1}"#.utf8))
        #expect(!settings.lens.changesImage && !settings.motionBlur.changesImage)
        let partial = try JSONDecoder().decode(Lens3D.self, from: Data(#"{"isEnabled":true,"distortion":0.2}"#.utf8))
        #expect(partial.distortion == 0.2 && partial.filmGrain == 0)
    }

    @Test func flatControlsRoundTripWithoutLosingOtherSettings() throws {
        var environment = Environment3D()
        environment.lensEnabled = true
        environment.lensDistortion = 0.2
        environment.chromaticAberration = 1.5
        environment.edgeSoftness = 1
        environment.filmGrain = 0.02
        environment.motionBlurEnabled = true
        environment.shutterAngle = 120
        environment.motionBlurMaximumVelocity = 20
        environment.motionBlurSamples = 6
        environment.depthOfFieldAperture = 0.3
        environment.autoExposureSpeedUp = 1.2
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.postProcess.lens == environment.postProcess.lens)
        #expect(decoded.postProcess.motionBlur == environment.postProcess.motionBlur)
        #expect(decoded.depthOfFieldAperture == 0.3 && decoded.autoExposureSpeedUp == 1.2)
        #expect(decoded.cameraEffectsWriteOutput && decoded.laterPassesWriteOutput)
        #expect(decoded.shadows.cascadeCount == environment.shadows.cascadeCount)
    }

    @Test func invalidParametersCannotReachTheShader() {
        let lens = Lens3D(isEnabled: true, distortion: .nan, chromaticAberration: -5, edgeSoftness: 100, filmGrain: .infinity).sanitized
        #expect(lens.distortion == 0 && lens.chromaticAberration == 0 && lens.edgeSoftness == 4 && lens.filmGrain == 0)
        let blur = MotionBlur3D(isEnabled: true, shutterAngle: 1000, maximumVelocity: -1, sampleCount: 300).sanitized
        #expect(blur.shutterAngle == 360 && blur.maximumVelocity == 0 && blur.sampleCount == 16)
        #expect(!blur.changesImage)
        #expect(!Lens3D(isEnabled: true).changesImage)
    }
}

extension Render3DGPUTests {
    @Suite("3D camera optics on GPU") @MainActor
    struct CameraEffects {
        private func difference(_ a: Image, _ b: Image) -> Int {
            GoldenFrame.compare(a, b, tolerance: GoldenFrame.activeTolerance).differingPixels
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func offAndStationaryMotionAreIdentityAndReleaseResources() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let baseline = try await scene.render(.none)
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            func views() throws -> CameraEffects3DViews { try #require(renderWorld.getResource(CameraEffects3DViews.self)) }
            #expect(try !views().hasScratch(view: scene.camera.id))
            try scene.configure { $0.motionBlurEnabled = true }
            let stationary = try await scene.render(.none)
            #expect(difference(baseline, stationary) == 0)
            #expect(try views().hasMotion(view: scene.camera.id))
            try scene.configure { $0.motionBlurEnabled = false }
            _ = try await scene.render(.none)
            #expect(try !views().hasScratch(view: scene.camera.id) && !views().hasMotion(view: scene.camera.id))
            // Compare against the old graph, with the new node physically removed.
            // Existing golden references may have other renderer changes in this checkout.
            var graph = try #require(renderWorld.getResource(RenderGraph.self))
            try graph.updateSubgraph(by: .main3D) {
                _ = $0.removeNode(by: CameraEffects3DRenderNode.name)
                $0.addNodeEdge(from: DepthOfField3DRenderNode.name, to: DebugView3DRenderNode.name)
            }
            renderWorld.insertResource(graph)
            #expect(difference(baseline, try await scene.render(.none)) == 0)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func lensChangesSceneAndDebugViewsBypassIt() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(farMarker: true)
            let baseline = try await scene.render(.none)
            try scene.configure { $0.postProcess.lens = Lens3D(isEnabled: true, distortion: 0.2, chromaticAberration: 2, edgeSoftness: 1) }
            let lens = try await scene.render(.none)
            #expect(difference(baseline, lens) > 1000)
            let normalLens = try await scene.render(.normals)
            try scene.configure { $0.lensEnabled = false }
            #expect(difference(normalLens, try await scene.render(.normals)) == 0)
            try scene.configure { $0.postProcess.lens = Lens3D(isEnabled: true, filmGrain: 0.1) }
            let grainA = try await scene.render(.none, frames: 1)
            let grainB = try await scene.render(.none, frames: 1)
            #expect(difference(grainA, grainB) > 1000, "Grain must change each rendered frame.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func rainBeadsRefractTheSceneAndFreezeAtTheAuthoredTime() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(farMarker: true)
            let dry = try await scene.render(.none)
            try scene.configure { $0.postProcess.lens = Lens3D(rainAmount: 1, rainTime: 4) }
            let wet = try await scene.render(.none)
            #expect(difference(dry, wet) > 1000)
            #expect(difference(wet, try await scene.render(.none)) == 0)
            try scene.configure { $0.rainLensTime = 8 }
            #expect(difference(wet, try await scene.render(.none)) > 1000)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func frameSubmissionAndReadbackCanOverlap() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.configure {
                $0.motionBlurEnabled = true
                $0.postProcess.lens = Lens3D(isEnabled: true, distortion: 0.12, filmGrain: 0.01)
                $0.depthOfFieldEnabled = true
            }
            _ = try await scene.render(.none)
            async let rendering: Void = Self.advance(scene)
            async let captures: Void = Self.readDuringRendering(scene)
            _ = try await (rendering, captures)
            _ = try await scene.render(.none)
        }

        private static func advance(_ scene: Render3DDebugViewGPUTests.Scene) async throws {
            for _ in 0..<60 { try await scene.app.update(); await Task.yield() }
        }

        private static func readDuringRendering(_ scene: Render3DDebugViewGPUTests.Scene) async throws {
            for _ in 0..<10 {
                let image = try #require(try await scene.device.readImage(from: scene.target))
                #expect(image.width == 640 && image.height == 480)
                await Task.yield()
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func motionBindGroupsStopGrowingAfterTheFrameRingWarmsUp() async throws {
            #if canImport(WebGPU)
            guard GoldenFrame.activeBackend == .webgpu else { return }
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.configure { $0.motionBlurEnabled = true }
            _ = try await scene.render(.none, frames: 8)
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let mesh = try #require(scene.sphereEntities.first?.components[Mesh3DComponent.self]?.mesh)
            let configuration = PBR3DConfiguration(vertex: mesh.models[0].parts[0].vertexDescriptor, blended: false)
            let cache = world.getRefResource(RenderPipelines<Motion3DPipeline>.self)
            let pipeline = try #require(cache.wrappedValue.pipeline(for: configuration, device: scene.device) as? WGPURenderPipeline)
            let warm = pipeline.cachedBindGroupCount
            _ = try await scene.render(.none, frames: 40)
            #expect(warm > 0 && pipeline.cachedBindGroupCount == warm,
                    "A camera uniform allocated every frame grows material bindings without bound.")
            #endif
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func multipleCamerasKeepTheirOwnInstanceBuffers() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.configure { $0.motionBlurEnabled = true }
            var environment = Environment3D()
            environment.motionBlurEnabled = true
            environment.screenSpaceReflection.isEnabled = false
            let target = RenderTexture(size: SizeInt(width: 320, height: 240), scaleFactor: 1, format: .bgra8)
            scene.app.main.spawn("Other camera", bundle: Camera3D(camera: Camera(renderTarget: target),
                transform: Transform(position: [2, 0.5, -3.4]), environment: environment))
            _ = try await scene.render(.none)
            let secondImage = try #require(try await scene.device.readImage(from: target))
            #expect(secondImage.width == 320 && secondImage.height == 240)
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            #expect(renderWorld.getResource(ActiveMotion3DPass.self)?.isEnabled == false)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func motionUsesCameraAndObjectHistoryAndResetsAfterCuts() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.configure { $0.postProcess.motionBlur = MotionBlur3D(isEnabled: true, shutterAngle: 360, maximumVelocity: 50, sampleCount: 12) }
            _ = try await scene.render(.none)
            var transform = try #require(scene.camera.components[Transform.self])
            transform.position.x += 0.18
            scene.camera.components[Transform.self] = transform
            // Extraction precedes transform propagation: drain the already prepared frame.
            _ = try await scene.render(.none, frames: 1)
            let movingCamera = try await scene.render(.none, frames: 1)
            let settledCamera = try await scene.render(.none, frames: 2)
            #expect(difference(movingCamera, settledCamera) > 100, "Camera movement must produce real velocity blur.")
            let object = try #require(scene.sphereEntities.first)
            // A smooth sphere has almost no high-frequency detail, and depth rejection intentionally
            // keeps its silhouette crisp. Give the moving surface real detail that can blur.
            let material = try #require(object.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial)
            var checker = Image(width: 64, height: 64, color: .white)
            for y in 0..<64 {
                for x in 0..<64 where (x / 4 + y / 4) % 2 == 0 { checker.setPixel(in: [Float(x), Float(y)], color: .black) }
            }
            material.baseColorTexture = Texture2D(image: checker)
            _ = try await scene.render(.none)
            var objectTransform = try #require(object.components[Transform.self])
            objectTransform.position.x += 0.2
            object.components[Transform.self] = objectTransform
            // The test edits outside a simulation callback; publish its world transform explicitly.
            object.components[GlobalTransform.self] = GlobalTransform(matrix: objectTransform.matrix)
            let movingObject = try await scene.render(.none, frames: 1)
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let source = try #require(renderWorld.getResource(ExtractedMesh3DSources.self)?.meshes.first { $0.entity == object.id })
            #expect(source.transform.origin.x != source.previousTransform.origin.x)
            let settledObject = try await scene.render(.none, frames: 2)
            #expect(difference(movingObject, settledObject) > 30, "Object movement must blur with a stationary camera.")
            transform.position.x += 3
            scene.camera.components[Transform.self] = transform
            _ = try await scene.render(.none, frames: 1)
            let cut = try await scene.render(.none, frames: 1)
            let settledCut = try await scene.render(.none, frames: 2)
            #expect(difference(cut, settledCut) == 0, "A teleport must reset history instead of leaving a trail.")
        }
    }
}
#endif
