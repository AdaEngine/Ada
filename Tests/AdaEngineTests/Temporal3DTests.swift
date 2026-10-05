import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

@testable import AdaCorePipelines
@testable import AdaECS

@Suite
struct Temporal3DHistoryTests {
    private let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: 1, zNear: 0.1, zFar: 100)
    private let input = SizeInt(width: 96, height: 96)
    private let output = SizeInt(width: 128, height: 128)

    @Test
    func resetsForCutsMissingFramesResizeAndExplicitGeneration() {
        var history = Temporal3DHistory()
        func prepare(_ frame: Int, view: Transform3D = .identity, size: SizeInt? = nil, generation: UInt64 = 0) -> Bool {
            history.prepare(frame: frame, view: view, projection: projection, inputSize: size ?? input, outputSize: output, settings: .init(resetGeneration: generation)).reset
        }
        #expect(prepare(1))
        #expect(!prepare(2, view: Transform3D(translation: [0.01, 0, 0])))
        #expect(prepare(4))
        #expect(prepare(5, view: Transform3D(translation: [10, 0, 0])))
        #expect(prepare(6, size: [64, 64]))
        #expect(prepare(7, size: [64, 64], generation: 1))
        #expect(!prepare(8, size: [64, 64], generation: 1))
    }

    @Test
    func historiesKeepDifferentCamerasIndependentAndResetProjection() {
        var a = Temporal3DHistory()
        var b = Temporal3DHistory()
        let first = a.prepare(frame: 1, view: .identity, projection: projection, inputSize: input, outputSize: output, settings: .init())
        let view = Transform3D(translation: [1, 0, 0])
        let other = b.prepare(frame: 1, view: view, projection: .identity, inputSize: [64, 64], outputSize: output, settings: .init())
        let second = a.prepare(frame: 2, view: view, projection: projection, inputSize: input, outputSize: output, settings: .init())
        #expect(first.reset && other.reset && !second.reset)
        #expect(second.previousViewProjection == projection)
        #expect(other.previousViewProjection == view)
        let changed = a.prepare(frame: 3, view: view, projection: .identity, inputSize: input, outputSize: output, settings: .init())
        #expect(changed.reset)
        #expect(changed.previousViewProjection == view)
    }

    @Test
    func jitterIsBoundedAndShiftsClipSpaceByTheRequestedInputPixels() {
        var sequence: [Vector2] = []
        for index in 0..<8 {
            let jitter = Temporal3DHistory.jitter(index: index)
            sequence.append(jitter)
            #expect(abs(jitter.x) <= 0.5 && abs(jitter.y) <= 0.5)
            let position = Vector4(0.2, 0.1, 5, 1)
            let original = projection * position
            let shifted = Temporal3DHistory.jittered(projection, offset: jitter, size: input) * position
            let pixelShift = (Vector2(shifted.x, shifted.y) / shifted.w - Vector2(original.x, original.y) / original.w) * Vector2(Float(input.width) / 2, -Float(input.height) / 2)
            let difference: Vector2 = pixelShift - jitter
            #expect(difference.squaredLength < 0.00000001)
        }
        #expect(sequence.dropFirst().allSatisfy { $0 != sequence[0] })
    }

    @Test
    func cameraRigidAndJointMotionPointToPreviousTopLeftUVWithoutJitter() {
        let point = Vector4(0, 0, 5, 1)
        let previous = projection * point
        let rigid = Transform3D(translation: [0.2, -0.1, 0]) * point
        let current = projection * rigid
        let motion = Temporal3DHistory.motion(current: current, previous: previous)
        #expect(motion.x < 0 && motion.y < 0)
        let joint = Transform3D(translation: [0, 0.3, 0]) * point
        let jointMotion = Temporal3DHistory.motion(current: projection * joint, previous: previous)
        #expect(jointMotion.y > 0)
        let view = Transform3D(translation: [-0.2, 0, 0])
        let viewProjection = projection * view
        #expect(Temporal3DHistory.motion(current: viewProjection * point, previous: previous).x > 0)
        #expect(Temporal3DHistory.motion(current: previous, previous: previous) == .zero)
        #expect(Temporal3DHistory.motion(current: previous, previous: [0, 0, 0, -1]) == .zero)
    }
}

@MainActor
@Suite
struct Temporal3DIntegrationTests {
    private func setup() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }

    @Test
    func unsupportedBackendLeavesTemporalDisabledAndUsesTheOrdinarySceneTarget() async throws {
        try setup()
        let world = World()
        world.insertResource(Temporal3DViews())
        world.insertResource(RenderDeviceHandler(renderDevice: HeadlessRenderBackend().renderDevice))
        var camera = Camera()
        camera.temporalUpscaling = .init()
        var target = RenderViewTarget()
        target.mainTexture = RenderTexture(size: [128, 128], scaleFactor: 1, format: .bgra8)
        target.outputTexture = target.mainTexture
        let entity = world.spawn {
            camera
            target
            GlobalViewUniform()
            ExtractedCameraSource(entityId: world.spawn().id)
            CameraRenderGraph(subgraphLabel: .main3D, inputSlot: Core3DPlugin.InputNode.view)
        }
        let system = PrepareTemporal3DSystem(world: world)
        system.queries.update(from: world)
        system.update(context: WorldUpdateContext(world: world, scheduler: "Temporal test"))
        await system.queries.finish(world)
        let result = try #require(entity.components[RenderViewTarget.self])
        #expect(!result.temporalUpscalingActive)
        #expect(result.temporalJitter == .zero)
        #expect(result.mainTexture === target.mainTexture)
        #expect(world.getResource(Temporal3DViews.self)?.entries.isEmpty == true)
    }

    @Test
    func previousSkinPaletteAndInstanceMatrixUseActualPriorPose() throws {
        try setup()
        let device = unsafe RenderEngine.shared.renderDevice
        let id = World().spawn().id
        var skins = Skinning3DUniforms()
        let rest = Transform3D(translation: [0, 0, 0])
        let moved = Transform3D(translation: [0.2, 0.5, 0])
        skins.beginFrame(device: device)
        _ = skins.write([rest], for: id, device: device)
        skins.beginFrame(device: device)
        let written = skins.write([moved], for: id, device: device)
        let current = try #require(written)
        let previous = try #require(skins.previousBuffer(for: id))
        #expect(current !== previous)
        let previousMatrix = unsafe previous.contents().load(as: Transform3D.self)
        let currentMatrix = unsafe current.contents().load(as: Transform3D.self)
        #expect(previousMatrix == rest)
        #expect(currentMatrix == moved)
        skins.beginFrame(device: device)
        skins.beginFrame(device: device)
        _ = skins.write([moved], for: id, device: device)
        let reappeared = try #require(skins.previousBuffer(for: id))
        #expect(unsafe reappeared.contents().load(as: Transform3D.self) == moved)
        let data = Flat3DInstanceData(modelMatrix: moved, color: .one, material: .zero, previousModelMatrix: rest)
        #expect(data.previousModelMatrix == rest)
        #expect(MemoryLayout<Flat3DInstanceData>.stride == 192)
    }

    @Test
    func failedTemporalEncodeResolvesBeforeUIAndRestoresOutputViewport() async throws {
        try setup()
        let device = HeadlessRenderBackend().renderDevice
        let world = World()
        let source = world.spawn().id
        var target = RenderViewTarget()
        target.temporalUpscalingActive = true
        target.temporalInputTexture = RenderTexture(size: [96, 96], scaleFactor: 1, format: .rgba_16f)
        target.temporalResolvedTexture = RenderTexture(size: [128, 128], scaleFactor: 1, format: .rgba_16f)
        target.mainTexture = RenderTexture(size: [128, 128], scaleFactor: 1, format: .bgra8)
        target.depthTexture = RenderTexture(size: [96, 96], scaleFactor: 1, format: .depth_32f)
        target.temporalMotionTexture = RenderTexture(size: [96, 96], scaleFactor: 1, format: .rgba_16f)
        target.temporalReactiveTexture = RenderTexture(size: [96, 96], scaleFactor: 1, format: .bgra8)
        target.temporalOutputDepthTexture = RenderTexture(size: [128, 128], scaleFactor: 1, format: .depth_32f_stencil8)
        var camera = Camera()
        camera.viewport.rect = Rect(x: 0, y: 0, width: 96, height: 96)
        let entity = world.spawn {
            camera
            target
            GlobalViewUniform()
            ExtractedCameraSource(entityId: source)
        }
        var views = Temporal3DViews()
        views.entries[source] = Temporal3DViews.Entry(scaler: RejectingTemporalUpscaler())
        world.insertResource(views)
        world.insertResource(Temporal3DPipelines(device: device))
        world.insertResource(VisibleMesh3DLists())
        world.insertResource(ActiveMotion3DPass())
        world.insertResource(RenderDeviceHandler(renderDevice: device))
        let statistics = Render3DTemporalStatistics()
        world.insertResource(statistics)
        var scene = RenderGraph(label: .main3D)
        scene.addNode(Temporal3DRenderNode())
        var root = RenderGraph()
        root.addSubgraph(scene, name: .main3D)
        root.addNode(TemporalTestViewNode(view: entity))
        root.update(from: world)
        try await RenderGraphExecutor().execute(root, renderDevice: device, in: world)
        let result = try #require(entity.components[Camera.self])
        #expect(result.viewport.rect.size == Size(width: 128, height: 128))
        #expect(statistics.snapshots["\(source)"]?.fallbackFrames == 1)
        #expect(world.getResource(Temporal3DViews.self)?.entries[source]?.encoded == false)
        #expect(world.getResource(ActiveMotion3DPass.self)?.isEnabled == false)
    }

    @Test
    func transparentMotionPreservesOpaqueVelocityAndWritesReactiveCoverage() throws {
        try setup()
        var descriptor = MeshDescriptor(name: "Temporal blend")
        descriptor.positions = MeshBuffer([Vector3.zero])
        let configuration = PBR3DConfiguration(vertex: descriptor.getMeshVertexBufferDescriptor(), blended: true, temporalDepth: true)
        var pipeline = Motion3DPipeline().configurate(with: configuration)
        #expect(pipeline.colorAttachments[0].sourceRGBBlendFactor == .zero)
        #expect(pipeline.colorAttachments[0].destinationRGBBlendFactor == .one)
        #expect(pipeline.colorAttachments[1].rgbBlendOperation == .max)
        #expect(pipeline.depthPixelFormat == .depth_32f)
        #expect(pipeline.depthStencilDescriptor?.isDepthWriteEnabled == false)
        #expect(pipeline.vertexDescriptor.attributes[16].offset == 128)
        #expect(PBR3DPipeline().configurate(with: configuration).depthPixelFormat == .depth_32f)
    }
}

private final class RejectingTemporalUpscaler: TemporalUpscaler {
    func encode(
        commandBuffer _: CommandBuffer,
        color _: Texture,
        depth _: Texture,
        motion _: Texture,
        reactive _: Texture,
        output _: Texture,
        jitter _: Vector2,
        reset _: Bool
    ) -> Bool { false }
}

private struct TemporalTestViewNode: RenderNode {
    let view: Entity
    func execute(context: inout Context, renderContext _: RenderContext) async throws -> [RenderSlotValue] {
        context.runSubgraph(.main3D, inputs: [], viewEntity: view)
        return []
    }
}
