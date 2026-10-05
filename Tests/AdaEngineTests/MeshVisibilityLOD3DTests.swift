@testable import AdaCorePipelines
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

@MainActor
@Suite
struct MeshVisibilityLOD3DTests {
    @Test
    func cameraAndShadowListsCullIndependentlyAndKeepOffscreenCasters() throws {
        try setup()
        let device = unsafe RenderEngine.shared.renderDevice
        let mesh = Mesh.generateCube(renderDevice: device)
        let material = PBRMaterial()
        let world = World()
        let camera1 = world.spawn().id, camera2 = world.spawn().id
        let a = source(world.spawn().id, mesh: mesh, material: material, at: [0, 0, 5])
        let b = source(world.spawn().id, mesh: mesh, material: material, at: [50, 0, 5])
        let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: 1, zNear: 0.1, zFar: 100)
        let shadow = Transform3D.orthographic(left: -60, right: 60, top: 10, bottom: -10, zNear: 0.1, zFar: 100)
        var lists = VisibleMesh3DLists(), uniforms = PBR3DUniforms()
        uniforms.beginFrame()
        lists.prepare(
            sources: [a, b],
            view: camera1,
            pass: -1,
            viewMatrix: .identity,
            projection: projection,
            cullingProjection: projection,
            settings: .init(),
            device: device,
            materials: &uniforms
        )
        lists.prepare(
            sources: [a, b],
            view: camera1,
            pass: 0,
            viewMatrix: .identity,
            projection: projection,
            cullingProjection: shadow,
            settings: .init(),
            device: device,
            materials: &uniforms
        )
        let movedView = Transform3D(translation: [50, 0, 0]).inverse
        lists.prepare(
            sources: [a, b],
            view: camera2,
            pass: -1,
            viewMatrix: movedView,
            projection: projection,
            cullingProjection: projection * movedView,
            settings: .init(),
            device: device,
            materials: &uniforms
        )
        #expect(lists.count(view: camera1, pass: -1).visibleMeshes == 1)
        #expect(lists.count(view: camera1, pass: -1).frustumRejected == 1)
        #expect(lists.items(view: camera1, pass: -1).first?.entity == a.entity)
        #expect(lists.count(view: camera1, pass: 0).visibleMeshes == 2)
        #expect(lists.count(view: camera1, pass: 0).triangles == 24)
        #expect(lists.items(view: camera2, pass: -1).first?.entity == b.entity)
        #expect(lists.buffers(view: camera1, pass: -1).instances?.buffer !== lists.buffers(view: camera2, pass: -1).instances?.buffer)
    }

    @Test
    func nearFarPlanesAndRotatedNonuniformBoundsAreConservative() {
        let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: 1, zNear: 0.1, zFar: 10)
        #expect(!MeshVisibility3DMath.intersects(AABB(center: [0, 0, -2], halfExtents: [0.1, 0.1, 0.1]), viewProjection: projection))
        #expect(!MeshVisibility3DMath.intersects(AABB(center: [0, 0, 11], halfExtents: [0.1, 0.1, 0.1]), viewProjection: projection))
        #expect(MeshVisibility3DMath.intersects(AABB(center: [0, 0, 0.1], halfExtents: [0.2, 0.2, 0.2]), viewProjection: projection))
        let bounds = AABB(center: .zero, halfExtents: [1, 2, 3])
        let matrix = Transform3D(translation: [3, 2, 4], rotation: Quat(axis: .up, angle: .pi / 2), scale: [2, 1, 0.5])
        let transformed = MeshVisibility3DMath.transformed(bounds, by: matrix)
        for x: Float in [-1, 1] {
            for y: Float in [-2, 2] {
                for z: Float in [-3, 3] {
                    let point = (matrix * Vector4(x, y, z, 1)).xyz
                    #expect(point.x >= transformed.min.x - 0.0001 && point.x <= transformed.max.x + 0.0001)
                    #expect(point.z >= transformed.min.z - 0.0001 && point.z <= transformed.max.z + 0.0001)
                }
            }
        }
    }

    @Test
    func screenSelectionHasHysteresisAndDistanceCutsDoNotAffectOtherViews() throws {
        #expect(MeshVisibility3DMath.selectLOD(size: 0.18, thresholds: [0.2, 0.08], levels: 3, previous: nil, hysteresis: 0.15) == 1)
        #expect(MeshVisibility3DMath.selectLOD(size: 0.205, thresholds: [0.2, 0.08], levels: 3, previous: 1, hysteresis: 0.15) == 1)
        #expect(MeshVisibility3DMath.selectLOD(size: 0.24, thresholds: [0.2, 0.08], levels: 3, previous: 1, hysteresis: 0.15) == 0)
        #expect(MeshVisibility3DMath.selectLOD(size: 0.05, thresholds: [0.2, 0.08], levels: 3, previous: 0, hysteresis: 0.15) == 2)
        try setup()
        let device = unsafe RenderEngine.shared.renderDevice
        let mesh = Mesh.generateSphere(segments: 24, rings: 16, renderDevice: device)
        let lower = Mesh.generateSphere(segments: 8, rings: 4, renderDevice: device)
        let world = World(), material = PBRMaterial()
        var source = source(world.spawn().id, mesh: mesh, material: material, at: [0, 0, 20])
        source.alternatives = [lower]; source.thresholds = [0.2]; source.maximumDistance = 30
        let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: 1, zNear: 0.1, zFar: 100)
        var lists = VisibleMesh3DLists(), uniforms = PBR3DUniforms()
        uniforms.beginFrame()
        let camera = world.spawn().id
        lists.prepare(
            sources: [source],
            view: camera,
            pass: -1,
            viewMatrix: .identity,
            projection: projection,
            cullingProjection: projection,
            settings: .init(),
            device: device,
            materials: &uniforms
        )
        let count = lists.count(view: camera, pass: -1)
        #expect(count.lodInstances[1] == 1)
        #expect(count.triangles < count.lod0Triangles)
        source.maximumDistance = 10
        lists.prepare(
            sources: [source],
            view: camera,
            pass: -1,
            viewMatrix: .identity,
            projection: projection,
            cullingProjection: projection,
            settings: .init(),
            device: device,
            materials: &uniforms
        )
        #expect(lists.count(view: camera, pass: -1).distanceRejected == 1)
    }

    @Test
    func posedInfluenceEnvelopeContainsTranslatedSkinAndNeverUsesRestPoseOnly() throws {
        try setup()
        var descriptor = MeshDescriptor(name: "Bounds skin")
        descriptor.positions = MeshBuffer([Vector3(0, 0, 0), [2, 0, 0], [0, 2, 0]])
        descriptor[MeshDescriptor.jointIndices] = MeshBuffer([Vector4(0, 1, 0, 0), [0, 1, 0, 0], [0, 1, 0, 0]])
        descriptor[MeshDescriptor.jointWeights] = MeshBuffer([Vector4(0.5, 0.5, 0, 0), [0.5, 0.5, 0, 0], [0.5, 0.5, 0, 0]])
        descriptor.indicies = [0, 1, 2]
        let mesh = Mesh.generate(from: [descriptor], renderDevice: unsafe RenderEngine.shared.renderDevice)
        let matrices = [Transform3D(translation: [0, 10, 0]), Transform3D(translation: [20, 10, 0])]
        var cache = AnimatedBounds3D()
        let computed = cache.bounds(mesh: mesh, matrices: matrices)
        let box = try #require(computed)
        #expect(box.min.y == 10 && box.max.y == 12)
        #expect(box.min.x <= 10 && box.max.x >= 22)
    }

    private func source(_ entity: Entity.ID, mesh: Mesh, material: Material, at position: Vector3) -> Mesh3DRenderSource {
        let transform = Transform3D(translation: position)
        return Mesh3DRenderSource(
            entity: entity,
            drawPass: Model3DDrawPass(),
            mesh: mesh,
            materials: [material],
            transform: transform,
            bounds: MeshVisibility3DMath.transformed(mesh.bounds, by: transform)
        )
    }

    private func setup() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }
}
