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

@testable import AdaCorePipelines

/// Morph target packing and selection; no GPU needed except where a texture is created.
@Suite("3D morph target selection")
struct Render3DMorphTargetSelectionTests {
    @Test func halfPrecisionConversionRoundTrips() {
        for value: Float in [0, 1, -1, 0.5, 0.6, -0.333, 100.25, 0.0001, 65504, -65504] {
            let half = MorphTargetSet.halfBits(value)
            let back = MorphTargetSet.float(fromHalfBits: half)
            #expect(abs(back - value) <= max(abs(value) * 0.001, 0.00001), "\(value) came back as \(back).")
        }
        #expect(MorphTargetSet.halfBits(1) == 0x3C00 && MorphTargetSet.halfBits(-2) == 0xC000 && MorphTargetSet.halfBits(0) == 0)
        #expect(MorphTargetSet.halfBits(1e9) == 0x7BFF && MorphTargetSet.halfBits(-1e9) == 0xFBFF, "Out-of-range values saturate to the largest finite half.")
        #expect(MorphTargetSet.float(fromHalfBits: MorphTargetSet.halfBits(1e-9)) == 0, "Values below the half range flush to zero.")
    }

    @Test func theHeaviestWeightsWin() {
        let weights: [Float] = [0.1, -0.9, 0, 0.5, 0.5, 2, .nan, 0.05, 0.3, 0.2, 0.4]
        let active = MorphTargetSet.activeTargets(weights: weights)
        #expect(active.count == 8)
        #expect(active.map(\.index) == [5, 1, 3, 4, 10, 8, 9, 0], "Largest magnitude first, ties by index; zero and NaN weights skipped.")
        #expect(active.first?.weight == 2 && active[1].weight == -0.9)
        #expect(MorphTargetSet.activeTargets(weights: [0, 0, .infinity]).isEmpty)
        #expect(MorphTargetSet.activeTargets(weights: [0.5, 0.6, 0.7], limit: 2).map(\.index) == [2, 1])
    }

    @Test func uniformPackingHoldsCurrentAndPreviousTargets() {
        var vectors = [Vector4](repeating: .one, count: Morph3DUniforms.vectorCountForTests)
        let current: [(index: Int, weight: Float)] = [(3, 0.5), (1, 0.25)]
        let previous: [(index: Int, weight: Float)] = [(3, 0.4)]
        // Only the counts, flags and entries matter, so a set is not needed to check the layout.
        Morph3DUniforms.packForTests(current: current, previous: previous, vertexCount: 120, attributes: 2, flags: 1, into: &vectors)
        #expect(vectors[0] == Vector4(2, 1, 120, 2) && vectors[1] == Vector4(1, 0, 0, 0))
        #expect(vectors[2] == Vector4(3, 0.5, 0, 0) && vectors[3] == Vector4(1, 0.25, 0, 0) && vectors[4] == .zero)
        #expect(vectors[10] == Vector4(3, 0.4, 0, 0) && vectors[11] == .zero)
    }

    @Test func morphKeysIdentifyModelAndPart() {
        #expect(Mesh3DRenderSource.morphKey(model: 0, part: 0) != Mesh3DRenderSource.morphKey(model: 1, part: 0))
        #expect(Mesh3DRenderSource.morphKey(model: 0, part: 1) != Mesh3DRenderSource.morphKey(model: 1, part: 0))
        #expect(Set((0..<4).flatMap { model in (0..<4).map { Mesh3DRenderSource.morphKey(model: model, part: $0) } }).count == 16)
    }

    @Test func componentRoundTripsThroughCodable() throws {
        let component = MorphWeights3DComponent(weights: [0.25, 1], targetNames: ["smile", "blink"])
        let decoded = try JSONDecoder().decode(MorphWeights3DComponent.self, from: JSONEncoder().encode(component))
        #expect(decoded.weights == [0.25, 1] && decoded.targetNames == ["smile", "blink"])
    }

    @Test func scriptsAndTheInspectorSteerOneTargetAtATime() throws {
        let descriptor = MorphWeights3DComponent.componentDescriptor
        func field(_ key: String) -> ReflectedComponentField? { descriptor.fields.first { $0.key == key } }
        #expect(field("selectedTarget")?.kind == .int && field("selectedTarget")?.isWritable == true)
        #expect(field("selectedTargetName")?.kind == .string && field("selectedTargetName")?.isWritable == true)
        #expect(field("selectedTargetWeight")?.kind == .float && field("selectedTargetWeight")?.isWritable == true)
        #expect(field("weights")?.isWritable == false, "Arrays are not reflected as editable fields.")

        var component = MorphWeights3DComponent(weights: [0, 0.5, 0], targetNames: ["smile", "blink", "frown"])
        component.selectedTargetName = "blink"
        #expect(component.selectedTarget == 1 && component.selectedTargetWeight == 0.5)
        component.selectedTargetWeight = 0.9
        #expect(component.weights == [0, 0.9, 0])
        component.selectedTargetWeight = .nan
        component.selectedTargetName = "unknown"
        #expect(component.weights == [0, 0.9, 0] && component.selectedTarget == 1, "Bad input leaves the component alone.")
        component.selectedTarget = 7
        component.selectedTargetWeight = 1
        #expect(component.weights == [0, 0.9, 0] && component.selectedTargetWeight == 0 && component.selectedTargetName.isEmpty)
        #expect(component.targetCount == 3)

        // Written back through reflection, as the inspector and AdaScript do.
        let written = try #require(field("selectedTargetWeight")?.write(MorphWeights3DComponent(weights: [0, 0], selectedTarget: 1), .double(0.75)) as? MorphWeights3DComponent)
        #expect(written.weights == [0, 0.75])
    }

    @Test func modelSourceKeepsAuthoredMorphWeightsAndDecodesOlderScenes() throws {
        let source = Model3DSource(source: "model.glb", morphWeights: ["smile": 0.5, "blink": 1])
        let decoded = try JSONDecoder().decode(Model3DSource.self, from: JSONEncoder().encode(source))
        #expect(decoded == source && decoded.morphWeights == ["smile": 0.5, "blink": 1])
        let older = try JSONDecoder().decode(Model3DSource.self, from: Data(#"{"source":"a.glb","animation":"","autoplay":false,"repeats":true}"#.utf8))
        #expect(older.morphWeights.isEmpty && older.source == "a.glb")
        #expect(Model3DSource(source: "a.glb") != source && Model3DSource(source: "model.glb", morphWeights: ["smile": 0.6]) != source)
    }

    @Test func componentFindsTargetsByName() {
        var component = MorphWeights3DComponent(weights: [0, 0.5], targetNames: ["smile", "blink"])
        #expect(component.weight(named: "blink") == 0.5 && component.weight(named: "frown") == nil)
        #expect(component.setWeight(1, named: "smile") && component.weights == [1, 0.5])
        #expect(!component.setWeight(1, named: "frown") && component.weights == [1, 0.5])
    }
}

extension Render3DGPUTests {
    /// Run alone: `ADAENGINE_GOLDEN_SAGA=1 swift test --filter Render3DGPUTests/MorphTargets`.
    @Suite("3D morph targets on GPU")
    @MainActor
    struct MorphTargets {
        /// A sphere with one target per entry of `shifts`, each moving every vertex by that vector at weight 1.
        private static func morphedSphere(device: RenderDevice, shifts: [Vector3], withNormalDeltas: Bool = false) throws -> Mesh {
            let base = Mesh.generateSphere(radius: 0.5, renderDevice: device)
            var part = try #require(base.models.first?.parts.first)
            let positions = part.meshDescriptor.positions.elements
            let normals = part.meshDescriptor.normals?.elements ?? []
            part.morphTargets = try #require(MorphTargetSet(
                positionDeltas: shifts.map { shift in positions.map { _ in shift } },
                // A normal delta that leans every normal toward +X.
                normalDeltas: shifts.map { _ in withNormalDeltas ? normals.map { _ in Vector3(0.8, 0, 0) } : [] },
                tangentDeltas: shifts.map { _ in [] },
                vertexCount: positions.count,
                targetNames: shifts.indices.map { "target \($0)" }
            ))
            return Mesh(models: [Mesh.Model(name: "Morphed", parts: [part])])
        }

        private struct Fixture {
            let scene: Render3DGPUTests.DebugViews.Scene
            let probe: Entity

            func place(at position: Vector3) {
                probe.components[Transform.self] = Transform(position: position)
            }

            func setWeights(_ weights: [Float]) {
                var component = probe.components[MorphWeights3DComponent.self]
                component?.weights = weights
                probe.components[MorphWeights3DComponent.self] = component
            }
        }

        private static let home: Vector3 = [-0.3, 0.5, -2.2]

        private static func makeFixture(shifts: [Vector3], withNormalDeltas: Bool = false, localLight: Bool = false) async throws -> Fixture {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let material = PBRMaterial()
            material.baseColorFactor = [0.7, 0.35, 0.3, 1]
            material.metallicFactor = 0
            material.roughnessFactor = 0.45
            let mesh = try morphedSphere(device: scene.device, shifts: shifts, withNormalDeltas: withNormalDeltas)
            let probe = scene.app.main.spawn("Probe") {
                Mesh3DComponent(mesh: mesh, materials: [material])
                MorphWeights3DComponent(weights: shifts.map { _ in 0 }, targetNames: mesh.morphTargetNames)
                Transform(position: home)
            }
            if localLight {
                scene.app.main.spawn("Shadow Point") {
                    PointLightComponent(radiance: [1, 0.9, 0.8], intensity: 10, castShadows: true, range: 6)
                    Transform(position: [1.4, 2.2, -1.4])
                }
            }
            return Fixture(scene: scene, probe: probe)
        }

        private static func matches(_ left: Image, _ right: Image) -> Bool {
            GoldenFrame.compare(left, right, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func zeroWeightsDrawTheRestShape() async throws {
            let fixture = try await Self.makeFixture(shifts: [[0.6, 0, 0]], localLight: true)
            let morphedMesh = try await fixture.scene.render(.none)
            // The same sphere without any morph data.
            var component = try #require(fixture.probe.components[Mesh3DComponent.self])
            let plain = Mesh.generateSphere(radius: 0.5, renderDevice: fixture.scene.device)
            component.mesh = plain
            fixture.probe.components[Mesh3DComponent.self] = component
            fixture.probe.components[MorphWeights3DComponent.self] = nil
            #expect(Self.matches(morphedMesh, try await fixture.scene.render(.none)), "Weight zero must look exactly like the unmorphed mesh.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled), arguments: [0.25 as Float, 0.5, 1])
        func aWeightedShiftMatchesMovingTheEntity(weight: Float) async throws {
            let fixture = try await Self.makeFixture(shifts: [[0.6, 0, 0]], localLight: true)
            fixture.setWeights([weight])
            let morphed = try await fixture.scene.render(.none)
            fixture.setWeights([0])
            fixture.place(at: Self.home + Vector3(0.6 * weight, 0, 0))
            let moved = try await fixture.scene.render(.none)
            #expect(Self.matches(morphed, moved), "A morph shift of \(0.6 * weight) must equal moving the entity by it, shadows from the sun and a local light included.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func weightsChangingEveryFrameUpdateTheShadows() async throws {
            let fixture = try await Self.makeFixture(shifts: [[0.6, 0, 0]], localLight: true)
            // Several settled frames, then a change: the local shadow faces must not be reused from before the change.
            fixture.setWeights([0.1])
            _ = try await fixture.scene.render(.none, frames: 4)
            fixture.setWeights([0.9])
            let morphed = try await fixture.scene.render(.none, frames: 1)
            fixture.setWeights([0])
            fixture.place(at: Self.home + Vector3(0.54, 0, 0))
            #expect(Self.matches(morphed, try await fixture.scene.render(.none, frames: 1)), "The shadows must follow the new weight on the first frame.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func onlyTheHeaviestEightTargetsApply() async throws {
            let shifts = (0..<10).map { Vector3(0.04 * Float($0 + 1), 0, 0) }
            let fixture = try await Self.makeFixture(shifts: shifts)
            let weights = (0..<10).map { 1 - 0.05 * Float($0) }
            fixture.setWeights(weights)
            let morphed = try await fixture.scene.render(.none)
            var expected: Float = 0
            for index in 0..<8 { expected += weights[index] * 0.04 * Float(index + 1) }
            fixture.setWeights([Float](repeating: 0, count: 10))
            fixture.place(at: Self.home + Vector3(expected, 0, 0))
            #expect(Self.matches(morphed, try await fixture.scene.render(.none)), "Targets nine and ten have the smallest weights and must be ignored.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func morphingBringsAnOffscreenMeshIntoView() async throws {
            // Resting far to the left, outside the frustum; the shift brings it to the middle. Culling must use the morphed bounds.
            let fixture = try await Self.makeFixture(shifts: [[8, 0, 0]])
            fixture.place(at: Vector3(-8.3, 0.5, -2.2))
            fixture.setWeights([1])
            let morphed = try await fixture.scene.render(.none)
            fixture.setWeights([0])
            fixture.place(at: Self.home)
            #expect(Self.matches(morphed, try await fixture.scene.render(.none)), "The morphed mesh must not be culled by its rest bounds.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func normalDeltasChangeTheShadingButNotTheShape() async throws {
            let fixture = try await Self.makeFixture(shifts: [[0, 0, 0]], withNormalDeltas: true)
            let rest = try await fixture.scene.render(.none)
            fixture.setWeights([1])
            let leaned = try await fixture.scene.render(.none)
            #expect(!Self.matches(rest, leaned), "Leaning the normals must change the lighting.")
            // The silhouette along the middle row is where the sphere meets the background, and it must not move.
            func edges(_ image: Image) -> [Int] {
                let background = image.getPixel(x: 2, y: 240)
                var result: [Int] = []
                var previousInside = false
                for x in 0..<640 {
                    let pixel = image.getPixel(x: x, y: 240)
                    let inside = abs(pixel.red - background.red) + abs(pixel.green - background.green) + abs(pixel.blue - background.blue) > 0.35
                    if inside != previousInside { result.append(x) }
                    previousInside = inside
                }
                return result
            }
            let restEdges = edges(rest)
            #expect(!restEdges.isEmpty && restEdges == edges(leaned), "Normal deltas move no vertex.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func morphedMeshesWorkWithGPUOcclusion() async throws {
            let fixture = try await Self.makeFixture(shifts: [[0.6, 0, 0]])
            try fixture.scene.configure { $0.gpuOcclusionEnabled = true }
            fixture.setWeights([0.7])
            let morphed = try await fixture.scene.render(.none)
            fixture.setWeights([0])
            fixture.place(at: Self.home + Vector3(0.42, 0, 0))
            #expect(Self.matches(morphed, try await fixture.scene.render(.none)), "The visibility prepass must draw the morphed shape.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func morphedMeshesDrawThroughTheTemporalMotionPass() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(temporalRenderScale: 1)
            let device = scene.device
            let material = PBRMaterial()
            material.baseColorFactor = [0.7, 0.35, 0.3, 1]
            material.metallicFactor = 0
            let mesh = try Self.morphedSphere(device: device, shifts: [[0.6, 0, 0]])
            let probe = scene.app.main.spawn("Probe") {
                Mesh3DComponent(mesh: mesh, materials: [material])
                MorphWeights3DComponent(weights: [0.5], targetNames: mesh.morphTargetNames)
                Transform(position: Self.home)
            }
            let fixture = Fixture(scene: scene, probe: probe)
            // Temporal accumulation is not exactly repeatable, so compare by which reference the frame is closer to.
            func difference(_ left: Image, _ right: Image) -> Int {
                GoldenFrame.compare(left, right, tolerance: GoldenFrame.activeTolerance).differingPixels
            }
            let morphed = try await scene.render(.none, frames: 16)
            fixture.setWeights([0])
            fixture.place(at: Self.home + Vector3(0.3, 0, 0))
            let moved = try await scene.render(.none, frames: 16)
            fixture.place(at: Self.home)
            let rest = try await scene.render(.none, frames: 16)
            let toMoved = difference(morphed, moved), toRest = difference(morphed, rest)
            #expect(toMoved * 4 < toRest, "Through the motion pass the morphed mesh must still land where its weights put it (\(toMoved) pixels from the moved mesh, \(toRest) from the rest shape).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func previousWeightsAreKeptForMotionVectors() async throws {
            let fixture = try await Self.makeFixture(shifts: [[0.6, 0, 0], [0, 0.6, 0]])
            let renderWorld = try #require(fixture.scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            func header() throws -> (current: Vector4, firstCurrent: Vector4, firstPrevious: Vector4) {
                let uniforms = try #require(renderWorld.getResource(Morph3DUniforms.self))
                let buffer = try #require(uniforms.debugBuffers().first)
                let vectors = unsafe (0..<18).map { buffer.contents().load(fromByteOffset: $0 * 16, as: Vector4.self) }
                return (vectors[0], vectors[2], vectors[10])
            }
            fixture.setWeights([0.2, 0])
            _ = try await fixture.scene.render(.none, frames: 3)
            fixture.setWeights([0.8, 0])
            _ = try await fixture.scene.render(.none, frames: 1)
            let moved = try header()
            #expect(moved.current.x == 1 && moved.current.y == 1)
            #expect(moved.firstCurrent == Vector4(0, 0.8, 0, 0) && moved.firstPrevious == Vector4(0, 0.2, 0, 0), "The previous frame's weight must sit next to the current one.")
            _ = try await fixture.scene.render(.none, frames: 1)
            let settled = try header()
            #expect(settled.firstCurrent == Vector4(0, 0.8, 0, 0) && settled.firstPrevious == Vector4(0, 0.8, 0, 0), "With nothing changing, previous equals current.")
        }

        /// A one-quad glTF skinned to a single joint that is turned a quarter turn about Z, with one morph target that moves
        /// every vertex by +0.6 on X (mesh weight 1 by default). Written to a temporary file and loaded like any asset.
        private static func skinnedMorphModel(animated: Bool = false) throws -> ModelAsset3D {
            var bytes = Data()
            var views: [[String: Any]] = []
            func add(_ data: Data) {
                views.append(["buffer": 0, "byteOffset": bytes.count, "byteLength": data.count])
                bytes.append(data)
                while bytes.count % 4 != 0 { bytes.append(0) }
            }
            func floats(_ values: [Float]) -> Data {
                var data = Data()
                for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
                return data
            }
            add(floats([-0.5, 0, 0, 0.5, 0, 0, -0.5, 1, 0, 0.5, 1, 0]))
            add(floats([0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1]))
            var indices = Data()
            for index in [0, 1, 2, 2, 1, 3] as [UInt16] { withUnsafeBytes(of: index.littleEndian) { indices.append(contentsOf: $0) } }
            add(indices)
            add(Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
            add(floats([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]))
            add(floats([0.6, 0, 0, 0.6, 0, 0, 0.6, 0, 0, 0.6, 0, 0]))
            add(floats([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]))
            // Animation keys: the weight goes from 0 to 1 over one second.
            add(floats([0, 1]))
            add(floats([0, 1]))
            func accessor(_ view: Int, _ type: String, _ count: Int, _ component: Int = 5126) -> [String: Any] {
                ["bufferView": view, "componentType": component, "count": count, "type": type]
            }
            var positionAccessor = accessor(0, "VEC3", 4)
            positionAccessor["min"] = [-0.5, 0, 0]
            positionAccessor["max"] = [0.5, 1, 0]
            var document: [String: Any] = [
                "asset": ["version": "2.0"],
                "buffers": [["byteLength": bytes.count, "uri": "data:application/octet-stream;base64," + bytes.base64EncodedString()]],
                "bufferViews": views,
                "accessors": [
                    positionAccessor, accessor(1, "VEC3", 4), accessor(2, "SCALAR", 6, 5123), accessor(3, "VEC4", 4, 5121),
                    accessor(4, "VEC4", 4), accessor(5, "VEC3", 4), accessor(6, "MAT4", 1),
                    accessor(7, "SCALAR", 2), accessor(8, "SCALAR", 2),
                ],
                "materials": [["doubleSided": true, "pbrMetallicRoughness": ["baseColorFactor": [0.8, 0.4, 0.3, 1], "metallicFactor": 0]]],
                "meshes": [[
                    "weights": [1],
                    "extras": ["targetNames": ["shift"]],
                    "primitives": [[
                        "attributes": ["POSITION": 0, "NORMAL": 1, "JOINTS_0": 3, "WEIGHTS_0": 4],
                        "indices": 2, "material": 0, "targets": [["POSITION": 5]],
                    ]],
                ]],
                "skins": [["joints": [1], "inverseBindMatrices": 6, "skeleton": 1]],
                "nodes": [["mesh": 0, "skin": 0], ["rotation": [0, 0, 0.7071068, 0.7071068]]],
                "scenes": [["nodes": [0, 1]]],
                "scene": 0,
            ]
            if animated {
                document["animations"] = [[
                    "name": "Open",
                    "samplers": [["input": 7, "output": 8, "interpolation": "LINEAR"]],
                    "channels": [["sampler": 0, "target": ["node": 0, "path": "weights"]]],
                ]]
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("morph-skin-\(UUID().uuidString).gltf")
            try JSONSerialization.data(withJSONObject: document).write(to: url)
            return try #require(AssetsManager.loadSync(ModelAsset3D.self, at: url.path).asset)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func animatedWeightsDriveTheMorphedMesh() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let model = try Self.skinnedMorphModel(animated: true)
            #expect(model.animationClips.map(\.name) == ["Open"] && model.animationClips[0].morphTracks.count == 1)
            let root = model.instantiate(in: scene.app.main)
            root.components[Transform.self] = Transform(position: [0, 0, -1.6])
            let mesh = try #require(Self.morphedEntity(under: root))
            var animation = try #require(root.components[ModelAnimation3DComponent.self])
            try animation.player.play("Open", transitionDuration: 0)
            animation.player.repeats = false
            animation.player.isPlaying = false
            animation.player.seek(to: 0.5)
            root.components[ModelAnimation3DComponent.self] = animation
            let animated = try await scene.render(.none, frames: 4)
            #expect(mesh.components[MorphWeights3DComponent.self]?.weights == [0.5], "The clip's weight at half a second must reach the entity.")
            // The same weight set by hand, with the animation out of the way.
            root.components[ModelAnimation3DComponent.self] = nil
            var component = try #require(mesh.components[MorphWeights3DComponent.self])
            component.weights = [0.5]
            mesh.components[MorphWeights3DComponent.self] = component
            #expect(Self.matches(animated, try await scene.render(.none, frames: 4)), "Animated weights must draw like the same weights set directly.")
            // And the end of the clip applies the full shift.
            var finished = animation
            finished.player.seek(to: 1)
            root.components[ModelAnimation3DComponent.self] = finished
            _ = try await scene.render(.none, frames: 2)
            #expect(mesh.components[MorphWeights3DComponent.self]?.weights == [1])
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func authoredWeightsStartTheInstanceAndYieldToAnimation() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            // A rigged model whose clips do not animate weights: the authored weight must survive the animation system.
            let still = try Self.skinnedMorphModel()
            // The owner carries the same reference, as in a scene; otherwise the source system treats the instance as stale.
            let reference = Model3DSource(source: "x", morphWeights: ["shift": 0.4, "unknown": 1])
            let owner = scene.app.main.spawn("Owner")
            owner.components[Model3DSource.self] = reference
            let root = try reference.instantiate(still, in: scene.app.main, under: owner)
            let mesh = try #require(Self.morphedEntity(under: root))
            #expect(mesh.components[MorphWeights3DComponent.self]?.weights == [0.4], "A name the model does not have is ignored.")
            _ = try await scene.render(.none, frames: 4)
            #expect(mesh.components[MorphWeights3DComponent.self]?.weights == [0.4], "Rest weights from the player must not overwrite authored ones.")
            // A model whose clip animates the weights: the clip takes over on the first pose.
            let animated = try Self.skinnedMorphModel(animated: true)
            let animatedReference = Model3DSource(source: "y", animation: "Open", autoplay: false, morphWeights: ["shift": 0.4])
            let animatedOwner = scene.app.main.spawn("Animated owner")
            animatedOwner.components[Model3DSource.self] = animatedReference
            let animatedRoot = try animatedReference.instantiate(animated, in: scene.app.main, under: animatedOwner)
            let animatedMesh = try #require(Self.morphedEntity(under: animatedRoot))
            _ = try await scene.render(.none, frames: 4)
            #expect(animatedMesh.components[MorphWeights3DComponent.self]?.weights == [0], "A clip that animates the weights owns them.")
        }

        private static func morphedEntity(under root: Entity) -> Entity? {
            if root.components[MorphWeights3DComponent.self] != nil { return root }
            for child in root.children {
                if let found = morphedEntity(under: child) { return found }
            }
            return nil
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func importedMorphTargetsApplyBeforeSkinning() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let model = try Self.skinnedMorphModel()
            #expect(model.meshes[0].hasMorphTargets && model.meshes[0].morphTargetNames == ["shift"] && model.meshMorphWeights == [[1]])
            let root = model.instantiate(in: scene.app.main)
            root.components[Transform.self] = Transform(position: [0, 0, -1.6])
            let mesh = try #require(Self.morphedEntity(under: root))
            #expect(mesh.components[MorphWeights3DComponent.self]?.weights == [1], "The file's default weight must reach the entity.")
            let morphed = try await scene.render(.none, frames: 4)
            // Morph first, then skin: the quarter turn carries the +0.6 X shift to +0.6 on Y. Skinning first would leave it on X.
            var component = try #require(mesh.components[MorphWeights3DComponent.self])
            component.weights = [0]
            mesh.components[MorphWeights3DComponent.self] = component
            root.components[Transform.self] = Transform(position: [0, 0.6, -1.6])
            let shiftedUp = try await scene.render(.none, frames: 4)
            root.components[Transform.self] = Transform(position: [0.6, 0, -1.6])
            let shiftedAcross = try await scene.render(.none, frames: 4)
            #expect(Self.matches(morphed, shiftedUp), "A morph shift must be turned by the skin (morph first, then skin).")
            #expect(!Self.matches(morphed, shiftedAcross))
        }
    }
}
#endif
