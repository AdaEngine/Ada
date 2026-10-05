@testable import AdaCorePipelines
@testable import AdaECS
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

@Suite
struct CascadedShadow3DTests {
    @Test
    func slicesCoverTheWholeFrustumAndIncreaseInDistance() {
        let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: 1.5, zNear: 0.1, zFar: 100)
        let cascades = DirectionalShadow3DMath.cascades(view: .identity, projection: projection, near: 0.1, far: 60, directionToLight: [0.3, 1, -0.3], count: 3, lambda: 0.65)
        #expect(cascades.count == 3)
        #expect(cascades[0].farDepth < cascades[1].farDepth)
        #expect(abs(cascades[2].farDepth - 60) < 0.001)
        #expect(cascades[0].radius < cascades[2].radius)
        for cascade in cascades {
            for corner in cascade.corners {
                let clip = cascade.viewProjection * Vector4(corner, 1)
                #expect(abs(clip.x) <= 1.0001 && abs(clip.y) <= 1.0001)
                #expect(clip.z > 0 && clip.z < 1)
            }
        }
    }

    @Test
    func subTexelMotionKeepsCascadeXYStable() {
        let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: 1, zNear: 0.1, zFar: 100)
        let first = DirectionalShadow3DMath.cascades(view: .identity, projection: projection, near: 0.1, far: 60, directionToLight: [0, 1, 0], count: 3, lambda: 0.65)
        let offset = first[0].radius * 2 / 1024 * 0.15
        let second = DirectionalShadow3DMath.cascades(
            view: Transform3D(translation: [offset, 0, 0]).inverse,
            projection: projection,
            near: 0.1,
            far: 60,
            directionToLight: [0, 1, 0],
            count: 3,
            lambda: 0.65
        )
        #expect(first[0].viewProjection == second[0].viewProjection)
    }

    @Test
    func oldEnvironmentDecodesWithEffectsDisabledAndSingleShadowCoverage() throws {
        let environment = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(!environment.ambientOcclusion.isEnabled)
        #expect(environment.antiAliasing == .none)
        #expect(environment.shadows.cascadeCount == 1)
    }
}

@MainActor
@Suite
struct RenderQuality3DIntegrationTests {
    @Test
    func prepareAllocatesOddSizedHalfResolutionAOAndReusesTargets() async throws {
        try setup()
        let world = World()
        let cameraSource = world.spawn().id
        var environments = ExtractedEnvironment3D()
        environments.environments[cameraSource] = Environment3D(ambientOcclusion: .init(isEnabled: true), antiAliasing: .fxaa)
        world.insertResource(environments)
        let scheduler: SchedulerName = "Quality Prepare Test"
        let prepare = PrepareEnvironment3DTexturesSystem(world: world)
        var target = RenderViewTarget()
        target.mainTexture = RenderTexture(size: [129, 65], scaleFactor: 1, format: .bgra8)
        let camera = world.spawn {
            Camera()
            CameraRenderGraph(subgraphLabel: .main3D, inputSlot: Core3DPlugin.InputNode.view)
            ExtractedCameraSource(entityId: cameraSource)
            target
        }
        prepare.queries.update(from: world)
        prepare.update(context: WorldUpdateContext(world: world, scheduler: scheduler))
        await prepare.queries.finish(world)
        let first = try #require(camera.components[RenderViewTarget.self])
        #expect(first.ambientOcclusion3DTexture?.size == SizeInt(width: 65, height: 33))
        #expect(first.indirectLighting3DTexture?.pixelFormat == .rgba_16f)
        #expect(first.antiAliasing3DInputTexture?.size == SizeInt(width: 129, height: 65))
        prepare.queries.update(from: world)
        prepare.update(context: WorldUpdateContext(world: world, scheduler: scheduler))
        await prepare.queries.finish(world)
        let second = try #require(camera.components[RenderViewTarget.self])
        #expect(first.ambientOcclusion3DTexture === second.ambientOcclusion3DTexture)
        #expect(first.indirectLighting3DTexture === second.indirectLighting3DTexture)
    }

    @Test
    func blendedMaterialsPreserveOpaqueGeometryAndAttenuateOnlyItsIndirectLight() throws {
        try setup()
        var vertex = MeshDescriptor(name: "Transparency")
        vertex.positions = MeshBuffer([Vector3.zero])
        let descriptor = PBR3DPipeline().configurate(with: .init(vertex: vertex.getMeshVertexBufferDescriptor(), blended: true))
        #expect(descriptor.colorAttachments.count == 4)
        for index in 1...2 {
            #expect(descriptor.colorAttachments[index].sourceRGBBlendFactor == .zero)
            #expect(descriptor.colorAttachments[index].destinationRGBBlendFactor == .one)
        }
        #expect(descriptor.colorAttachments[3].sourceRGBBlendFactor == .zero)
        #expect(descriptor.colorAttachments[3].destinationRGBBlendFactor == .oneMinusSourceAlpha)
        #expect(descriptor.depthStencilDescriptor?.isDepthWriteEnabled == false)
    }

    @Test
    func cameraUniformRingsNeverShareBuffersAndMetricsIgnoreMissingGPUTimestamps() throws {
        try setup()
        let world = World()
        let first = world.spawn().id, second = world.spawn().id
        let device = unsafe RenderEngine.shared.renderDevice
        var cache = FrameUniformCache3D<Vector4>()
        let a = cache.write([1, 0, 0, 0], view: first, device: device)
        let b = cache.write([0, 1, 0, 0], view: second, device: device)
        #expect(a.buffer !== b.buffer)
        let metrics = Render3DPerformanceMetrics(warmupSamples: 1)
        metrics.record(pass: "test", seconds: nil)
        metrics.record(pass: "test", seconds: 0.01)
        metrics.record(pass: "test", seconds: 0.002)
        metrics.record(pass: "test", seconds: 0.004)
        let sample = try #require(metrics.samples.first)
        #expect(sample.count == 2)
        #expect(sample.averageMilliseconds == 3)
    }

    private func setup() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }
}
