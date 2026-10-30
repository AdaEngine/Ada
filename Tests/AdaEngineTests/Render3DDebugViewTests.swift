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
#if canImport(Metal)
import Metal
#endif
import Testing

@testable import AdaCorePipelines

/// Debug views and golden frames that need no GPU.
@Suite("3D debug view settings")
struct Render3DDebugViewSettingsTests {
    @Test func environmentDefaultsToNormalRendering() {
        #expect(Environment3D().debugView == DebugView3D.none)
    }

    @Test func legacyEnvironmentPayloadDecodesWithoutDebugView() throws {
        let legacy = try JSONEncoder().encode(Environment3D())
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object.removeValue(forKey: "debugView")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Environment3D.self, from: stripped)
        #expect(decoded.debugView == DebugView3D.none)
    }

    @Test(arguments: DebugView3D.allCases)
    func debugViewRoundTrips(view: DebugView3D) throws {
        var environment = Environment3D()
        environment.debugView = view
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.debugView == view)
    }

    @Test func onlyFullscreenViewsReplaceTheFinalImage() {
        let replacing = DebugView3D.allCases.filter(\.replacesFinalImage)
        #expect(!replacing.contains(.none))
        #expect(!replacing.contains(.wireframe))
        #expect(replacing.count == DebugView3D.allCases.count - 2)
        // Views that read a dedicated target select their own shader branch; the three views the main pass
        // colors itself share the scene-color branch but select distinct main-pass modes.
        let mainPass = replacing.filter { $0.mainPassMode > 0 }
        #expect(Set(mainPass.map(\.shaderMode)) == [7])
        #expect(Set(mainPass.map(\.mainPassMode)).count == mainPass.count)
        let ownTargets = replacing.filter { $0.mainPassMode == 0 }
        #expect(Set(ownTargets.map(\.shaderMode)).count == ownTargets.count)
        #expect(Set(ownTargets.map(\.shaderMode)).isDisjoint(with: [7]))
    }
}

/// Immediate-mode debug draw queue semantics that need no GPU.
@Suite("3D debug draw queue")
struct Render3DDebugDrawQueueTests {
    @Test func shapesLiveForTheirDurationThenExpire() {
        let draw = DebugDraw3D()
        draw.line(from: .zero, to: [1, 0, 0])
        draw.line(from: .zero, to: [0, 1, 0], duration: 3)
        #expect(draw.lineCount == 2)
        #expect(draw.drainFrame().count == 2)
        // One-frame shapes are gone after their first frame; the three-frame shape remains.
        #expect(draw.lineCount == 1)
        #expect(draw.drainFrame().count == 1)
        #expect(draw.drainFrame().count == 1)
        #expect(draw.drainFrame().isEmpty)
        #expect(draw.lineCount == 0)
    }

    @Test func nonPositiveDurationStillDrawsOnce() {
        let draw = DebugDraw3D()
        draw.line(from: .zero, to: .one, duration: 0)
        draw.line(from: .zero, to: .one, duration: -4)
        #expect(draw.drainFrame().count == 2)
        #expect(draw.lineCount == 0)
    }

    @Test func shapeBuildersEmitExpectedSegmentCounts() {
        let draw = DebugDraw3D()
        draw.box(halfExtents: [1, 2, 3])
        #expect(draw.lineCount == 12)
        draw.aabb(AABB(min: [-1, -1, -1], max: [1, 1, 1]))
        #expect(draw.lineCount == 24)
        draw.sphere(center: .zero, radius: 1, segments: 16)
        #expect(draw.lineCount == 24 + 16 * 3)
        draw.axes(transform: .identity, length: 2)
        #expect(draw.lineCount == 24 + 48 + 3)
        draw.polyline([.zero, [1, 0, 0], [1, 1, 0]], closed: true)
        #expect(draw.lineCount == 24 + 48 + 3 + 3)
        draw.polyline([.zero], closed: true)
        #expect(draw.lineCount == 24 + 48 + 3 + 3)
    }

    @Test func frustumOfAnIdentityViewIsABox() {
        let draw = DebugDraw3D()
        // NDC x/y span -1...1 and depth 0...1, so the inverse of identity is the unit slab.
        draw.frustum(viewProjection: .identity)
        let lines = draw.drainFrame()
        #expect(lines.count == 12)
        let points = lines.flatMap { [$0.start, $0.end] }
        #expect(points.allSatisfy { abs($0.x) == 1 && abs($0.y) == 1 && ($0.z == 0 || $0.z == 1) })
    }

    @Test func boxEdgesFollowTheTransform() throws {
        let draw = DebugDraw3D()
        draw.box(transform: Transform3D(translation: [10, 0, 0], rotation: .identity, scale: .one), halfExtents: .one)
        let points = draw.drainFrame().flatMap { [$0.start, $0.end] }
        #expect(points.map(\.x).min() == 9)
        #expect(points.map(\.x).max() == 11)
    }

    @Test func invalidInputIsRejected() {
        let draw = DebugDraw3D()
        draw.line(from: [.nan, 0, 0], to: .zero)
        draw.line(from: .zero, to: [.infinity, 0, 0])
        draw.sphere(center: .zero, radius: 0)
        draw.sphere(center: .zero, radius: -1)
        draw.sphere(center: [.nan, 0, 0], radius: 1)
        draw.box(halfExtents: [.nan, 1, 1])
        #expect(draw.lineCount == 0)
    }

    @Test func queueIsBoundedAndCountsDroppedLines() {
        let draw = DebugDraw3D(maximumLineCount: 10)
        draw.sphere(center: .zero, radius: 1, segments: 8)
        #expect(draw.lineCount == 10)
        #expect(draw.droppedLineCount == 14)
        draw.clear()
        #expect(draw.lineCount == 0)
        #expect(draw.droppedLineCount == 0)
    }

    @Test func extractionAgesTheQueueOncePerRenderedFrame() async {
        let main = World()
        let draw = DebugDraw3D()
        main.insertResource(draw)
        draw.line(from: .zero, to: .one)
        let render = World()
        render.insertResource(MainWorld(world: main))
        render.insertResource(ExtractedDebugLines3D())
        render.addSystem(ExtractDebugDraw3DSystem.self, on: .extract)
        await render.runScheduler(.extract)
        #expect(render.getResource(ExtractedDebugLines3D.self)?.lines.count == 1)
        await render.runScheduler(.extract)
        #expect(render.getResource(ExtractedDebugLines3D.self)?.lines.isEmpty == true)
    }
}

/// Golden-frame harness logic that needs no GPU.
@Suite("Golden frame comparison")
struct GoldenFrameComparisonTests {
    private func solid(_ red: Float, width: Int = 8, height: Int = 8) -> Image {
        Image(width: width, height: height, color: Color(red: red, green: 0.5, blue: 0.5))
    }

    @Test func identicalImagesMatch() {
        let result = GoldenFrame.compare(solid(0.2), solid(0.2), tolerance: GoldenFrame.activeTolerance)
        #expect(result.differingPixels == 0)
        #expect(result.passes(GoldenFrame.activeTolerance))
    }

    @Test func differencesWithinChannelToleranceAreIgnored() {
        // 1/255 apart is below the two-step channel tolerance.
        let result = GoldenFrame.compare(solid(0.2), solid(0.2 + 1.0 / 255), tolerance: GoldenFrame.activeTolerance)
        #expect(result.differingPixels == 0)
    }

    @Test func differencesBeyondToleranceFail() {
        var changed = solid(0.2)
        changed.setPixel(in: [3, 3], color: Color(red: 1, green: 0, blue: 0))
        let result = GoldenFrame.compare(changed, solid(0.2), tolerance: GoldenFrame.activeTolerance)
        #expect(result.differingPixels == 1)
        #expect(result.largestStep > 2)
        #expect(!result.passes(GoldenFrame.activeTolerance))
        // A looser fraction accepts the single pixel.
        #expect(result.passes(GoldenFrame.Tolerance(channelSteps: 2, differingFraction: 0.05)))
    }

    @Test func sizeMismatchAlwaysFails() {
        let result = GoldenFrame.compare(solid(0.2, width: 8), solid(0.2, width: 4), tolerance: GoldenFrame.Tolerance(channelSteps: 255, differingFraction: 1))
        #expect(result.sizeMismatch)
        #expect(!result.passes(GoldenFrame.Tolerance(channelSteps: 255, differingFraction: 1)))
    }
}

extension Render3DGPUTests {
    /// Renders a lit PBR scene through the real Metal pipeline for each debug view and checks the frames
    /// against golden references.
    ///
    /// Run alone: `ADAENGINE_GOLDEN_METAL=1 swift test --filter Render3DDebugViewGPUTests`.
    /// Record references with `ADAENGINE_GOLDEN_RECORD=1`; set `ADAENGINE_GOLDEN_OUTPUT` to keep actual frames.
    /// Other integration suites initialize the process-wide engine as headless.
    @Suite("3D debug views on GPU")
    @MainActor
    struct DebugViews {
        static let width = 640
        static let height = 480
        /// Roughness and metallic of the four spheres from left to right.
        private static let roughness: [Float] = [0.1, 0.35, 0.65, 0.9]
        private static let metallic: [Float] = [0, 0.33, 0.66, 1]

        struct Scene {
            let app: AppWorlds
            let device: RenderDevice
            let target: RenderTexture
            /// Metal only: a fence on the engine's queue. WebGPU readback waits for submitted work itself.
            #if canImport(Metal)
            let queue: MTLCommandQueue?
            #endif
            let camera: Entity
            let sun: Entity
            /// The ground's material, which tests edit between renders.
            var groundMaterial: PBRMaterial?
            var sphereEntities: [Entity] = []

            /// Scales the sun's intensity, which changes how bright the whole lit scene is.
            func setSunIntensity(_ intensity: Float) throws {
                var light = try #require(sun.components[DirectionalLightComponent.self])
                light.intensity = intensity
                sun.components[DirectionalLightComponent.self] = light
            }

            /// Edits the camera's environment before the next rendered frame.
            func configure(_ change: (inout Environment3D) -> Void) throws {
                var environment = try #require(camera.components[Environment3D.self])
                change(&environment)
                camera.components[Environment3D.self] = environment
            }

            func render(_ view: DebugView3D, frames: Int = 4) async throws -> Image {
                var environment = try #require(camera.components[Environment3D.self])
                environment.debugView = view
                camera.components[Environment3D.self] = environment
                for _ in 0..<frames {
                    try await app.update()
                }
                #if canImport(Metal)
                if let queue {
                    let fence = try #require(queue.makeCommandBuffer())
                    await withCheckedContinuation { continuation in
                        fence.addCompletedHandler { _ in continuation.resume() }
                        fence.commit()
                    }
                }
                #endif
                return try #require(try await device.readImage(from: target))
            }
        }

        static func makeScene(
            emissiveSphere: Bool = false,
            farMarker: Bool = false,
            antiAliasing: AntiAliasing3D = .none,
            temporalRenderScale: Float? = nil,
            pathTracingPresentation: Bool = false
        ) async throws -> Scene {
            let backend = GoldenFrame.activeBackend ?? .metal
            let requested: RenderBackendType = backend == .webgpu ? .webgpu : .metal
            unsafe RenderEngine.configurations.preferredBackend = requested
            try RenderEngine.setupRenderEngine()
            // A silent fallback to another backend would make the references meaningless.
            try #require(unsafe RenderEngine.shared.type == requested, "The \(backend) backend must be active.")
            let device = unsafe RenderEngine.shared.renderDevice
            #if canImport(Metal)
            let queue = backend == .metal ? try #require(MetalInterop.commandQueue(for: device)) : nil
            #endif
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
                .addPlugin(Core3DPlugin(pathTracingPresentation:pathTracingPresentation))
            if temporalRenderScale != nil {
                // Temporal upscaling renders into a private texture that the upscale node copies to the target.
                app.addPlugin(UpscalePlugin())
            }
            try await app.build()

            let target = RenderTexture(size: SizeInt(width: width, height: height), scaleFactor: 1, format: .bgra8)
            var environment = Environment3D(ambientOcclusion: .init(isEnabled: true), antiAliasing: antiAliasing)
            environment.skybox.isEnabled = false
            environment.screenSpaceReflection.isEnabled = false
            var camera = Camera(renderTarget: target)
            camera.backgroundColor = Color(red: 0.55, green: 0.7, blue: 0.9)
            if let temporalRenderScale {
                camera.temporalUpscaling = TemporalUpscalingSettings(renderScale: temporalRenderScale)
            }
            // The camera looks along +Z at sphere centers, so the middle image row crosses all four spheres.
            let cameraEntity = app.main.spawn(
                "Camera",
                bundle: Camera3D(camera: camera, transform: Transform(position: [0, 0.5, -3.4]), environment: environment)
            )
            let sunEntity = app.main.spawn("Sun") {
                DirectionalLightComponent(radiance: [1, 0.95, 0.85], intensity: 3, castShadows: true)
                Transform(rotation: Quat.euler([-0.9, 0.6, 0]))
            }
            let sphere = Mesh.generateSphere(radius: 0.5, renderDevice: device)
            var sphereEntities: [Entity] = []
            for index in 0..<4 {
                let material = PBRMaterial()
                material.baseColorFactor = [0.8, 0.45, 0.3, 1]
                material.roughnessFactor = roughness[index]
                material.metallicFactor = metallic[index]
                let entity = app.main.spawn("Sphere \(index)") {
                    Mesh3DComponent(mesh: sphere, materials: [material])
                    Transform(position: [Float(index) * 1.1 - 1.65, 0.5, 0])
                }
                sphereEntities.append(entity)
            }
            if emissiveSphere {
                // An HDR light source above the row, against the sky, so bloom is visible outside its silhouette.
                let emitter = PBRMaterial()
                emitter.baseColorFactor = [0.05, 0.05, 0.05, 1]
                emitter.emissiveFactor = [1, 0.85, 0.55]
                emitter.emissiveStrength = 14
                app.main.spawn("Emitter") {
                    Mesh3DComponent(mesh: sphere, materials: [emitter], castShadows: false, receiveShadows: false)
                    Transform(position: [0, 1.9, 0])
                }
            }
            if farMarker {
                // A dark sphere well behind the row (depth 7.4 from the camera), clear of it on screen, so its
                // edge against the sky shows how much the far plane is blurred.
                let dark = PBRMaterial()
                dark.baseColorFactor = [0.03, 0.03, 0.04, 1]
                dark.roughnessFactor = 1
                dark.metallicFactor = 0
                app.main.spawn("Far marker") {
                    Mesh3DComponent(mesh: sphere, materials: [dark], castShadows: false, receiveShadows: false)
                    Transform(position: [1, 2.2, 4])
                }
            }
            let ground = PBRMaterial()
            ground.baseColorFactor = [0.35, 0.4, 0.35, 1]
            ground.roughnessFactor = 0.9
            ground.metallicFactor = 0
            app.main.spawn("Ground") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [10, 0.1, 10], renderDevice: device), materials: [ground])
                Transform(position: [0, -0.05, 0])
            }
            #if canImport(Metal)
            return Scene(app: app, device: device, target: target, queue: queue, camera: cameraEntity, sun: sunEntity,
                         groundMaterial: ground, sphereEntities: sphereEntities)
            #else
            return Scene(app: app, device: device, target: target, camera: cameraEntity, sun: sunEntity,
                         groundMaterial: ground, sphereEntities: sphereEntities)
            #endif
        }

        private static func expectGolden(_ image: Image, named name: String) throws {
            switch try GoldenFrame.check(image, name: name) {
            case .recorded, .matched:
                break
            case .missingReference(let actual):
                Issue.record("No golden frame for \(name); record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
            case let .mismatched(comparison, actual, difference):
                Issue.record("\(name) differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
            }
        }

        /// Colors at the center of each run of lit (non-placeholder) pixels along one row, left to right.
        private static func runCenterColors(in image: Image, row: Int, threshold: Float = 0.12) -> [Color] {
            var centers: [Color] = []
            var start: Int?
            for x in 0...image.width {
                let covered = x < image.width && max(image.getPixel(x: x, y: row).red, image.getPixel(x: x, y: row).green, image.getPixel(x: x, y: row).blue) > threshold
                if covered, start == nil {
                    start = x
                } else if !covered, let begin = start {
                    if x - begin > 12 {
                        centers.append(image.getPixel(x: (begin + x) / 2, y: row))
                    }
                    start = nil
                }
            }
            return centers
        }

        /// Gray levels (0...1) at the center of each covered run on one image row, left to right.
        private static func runCenters(in image: Image, row: Int, threshold: Float = 0.08) -> [Float] {
            var centers: [Float] = []
            var start: Int?
            for x in 0...image.width {
                let covered = x < image.width && image.getPixel(x: x, y: row).red > threshold
                if covered, start == nil {
                    start = x
                } else if !covered, let begin = start {
                    if x - begin > 12 {
                        centers.append(image.getPixel(x: (begin + x) / 2, y: row).red)
                    }
                    start = nil
                }
            }
            return centers
        }

        nonisolated static let enabled = GoldenFrame.isEnabled

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func roughnessAndMetallicViewsReportMaterialValues() async throws {
            let scene = try await Self.makeScene()
            let roughness = try await scene.render(.roughness)
            let metallic = try await scene.render(.metallic)
            let middle = Self.height / 2
            let roughnessLevels = Self.runCenters(in: roughness, row: middle)
            let metallicLevels = Self.runCenters(in: metallic, row: middle)
            // Metallic zero renders at the dark floor of the view, so runs are found by roughness only.
            #expect(roughnessLevels.count >= 4)
            for (level, expected) in zip(roughnessLevels, Self.roughness) {
                #expect(abs(level - expected) < 0.06, "roughness level \(level) should be near \(expected)")
            }
            #expect(metallicLevels.count >= 3)
            #expect(metallicLevels.last.map { $0 > 0.9 } == true)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func everyViewMatchesItsGoldenFrame() async throws {
            let scene = try await Self.makeScene()
            let beauty = try await scene.render(.none)
            for view in DebugView3D.allCases {
                let image = view == .none ? beauty : try await scene.render(view)
                // The WebGPU encoder has no polygon fill mode, so wireframe renders solid there.
                let isNoOp = view == .none || (view == .wireframe && GoldenFrame.activeBackend == .webgpu)
                if !isNoOp {
                    #expect(image.data != beauty.data, "\(view) must change the image")
                }
                let name = "pbr-spheres-\(view.rawValue)"
                switch try GoldenFrame.check(image, name: name) {
                case .recorded, .matched:
                    break
                case .missingReference(let actual):
                    Issue.record("No golden frame for \(name); record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
                case let .mismatched(comparison, actual, difference):
                    Issue.record("\(name) differs in \(comparison.differingPixels) pixels (largest step \(comparison.largestStep)). Actual: \(actual.path), difference: \(difference.path)")
                }
            }
        }

        /// Number of runs of pixels matching `predicate` along one image row.
        private static func runs(in image: Image, row: Int, where predicate: (Color) -> Bool) -> Int {
            var count = 0
            var inRun = false
            for x in 0..<image.width {
                let matches = predicate(image.getPixel(x: x, y: row))
                if matches, !inRun { count += 1 }
                inRun = matches
            }
            return count
        }

        private static func isRed(_ color: Color) -> Bool { color.red > 0.9 && color.green < 0.1 && color.blue < 0.1 }
        private static func isMagenta(_ color: Color) -> Bool { color.red > 0.9 && color.green < 0.1 && color.blue > 0.9 }
        private static func isGreen(_ color: Color) -> Bool { color.green > 0.9 && color.red < 0.1 && color.blue < 0.1 }

        /// The image row with the most pixels matching `predicate`, and that count.
        private static func densestRow(in image: Image, where predicate: (Color) -> Bool) -> (row: Int, count: Int) {
            var best = (row: 0, count: 0)
            for row in 0..<image.height {
                var count = 0
                for x in 0..<image.width where predicate(image.getPixel(x: x, y: row)) { count += 1 }
                if count > best.count { best = (row, count) }
            }
            return best
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func debugDrawIsDepthTestedExpiresAndMatchesItsGoldenFrame() async throws {
            let scene = try await Self.makeScene()
            let draw = try #require(scene.app.main.getResource(DebugDraw3D.self))
            let baseline = try await scene.render(.none)

            // Behind spheres one to three: the depth-tested line is visible only in the gaps between them.
            draw.line(from: [-1.4, 0.5, 0.9], to: [0.3, 0.5, 0.9], color: Color(red: 1, green: 0, blue: 1), duration: 8)
            // Same depth behind the third sphere (x 0.55) but drawn on top: the green line must stay whole.
            draw.line(from: [-0.3, 0.75, 0.9], to: [1.4, 0.75, 0.9], color: .green, duration: 8, depthTested: false)
            draw.box(transform: Transform3D(translation: [0, 1.7, 0], rotation: .identity, scale: .one), halfExtents: [0.4, 0.2, 0.4], color: .white, duration: 8)
            draw.axes(transform: Transform3D(translation: [-1.9, 0, -0.9], rotation: .identity, scale: .one), length: 0.6, duration: 8)
            let drawn = try await scene.render(.none)

            let tested = Self.densestRow(in: drawn, where: Self.isMagenta)
            #expect(tested.count > 10, "The depth-tested line must be visible outside the sphere silhouettes.")
            #expect(tested.count < 60, "The spheres must hide most of the depth-tested line (\(tested.count) pixels visible).")
            #expect(Self.runs(in: drawn, row: tested.row, where: Self.isMagenta) >= 2, "The spheres must split the depth-tested line into separate pieces.")
            let green = Self.densestRow(in: drawn, where: Self.isGreen)
            #expect(green.count > 100)
            #expect(Self.runs(in: drawn, row: green.row, where: Self.isGreen) == 1, "The overlay line must not be cut by the scene.")

            switch try GoldenFrame.check(drawn, name: "pbr-spheres-debugdraw") {
            case .recorded, .matched:
                break
            case .missingReference(let actual):
                Issue.record("No golden frame for debug draw; record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
            case let .mismatched(comparison, actual, difference):
                Issue.record("Debug draw differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
            }

            // Shapes drawn for eight frames are gone once the queue ages out, restoring the baseline image.
            draw.clear()
            let restored = try await scene.render(.none)
            let comparison = GoldenFrame.compare(baseline, restored, tolerance: GoldenFrame.activeTolerance)
            #expect(comparison.passes(GoldenFrame.activeTolerance), "Cleared debug draw must leave no pixels behind (\(comparison.differingPixels) differ).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func oneFrameShapesAppearForExactlyOneRenderedFrame() async throws {
            let scene = try await Self.makeScene()
            let draw = try #require(scene.app.main.getResource(DebugDraw3D.self))
            let baseline = try await scene.render(.none)
            draw.line(from: [-1.5, 0.5, -1], to: [1.5, 0.5, -1], color: .red)
            let withLine = try await scene.render(.none, frames: 1)
            #expect(Self.densestRow(in: withLine, where: Self.isRed).count > 100)
            let after = try await scene.render(.none, frames: 1)
            #expect(GoldenFrame.compare(baseline, after, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func albedoViewShowsBaseColorWhateverTheLighting() async throws {
            let scene = try await Self.makeScene()
            let image = try await scene.render(.albedo)
            // Ground base color (0.35, 0.40, 0.35) linear encodes to roughly (160, 170, 160) in sRGB.
            let ground = image.getPixel(x: 320, y: 440)
            #expect(abs(ground.red * 255 - 160) <= 3 && abs(ground.green * 255 - 170) <= 3 && abs(ground.blue * 255 - 160) <= 3, "ground albedo was \(ground)")
            // Sphere base color (0.8, 0.45, 0.3) encodes to roughly (231, 179, 149), shaded or not.
            let row = Self.height / 2
            let centers = Self.runCenterColors(in: image, row: row)
            #expect(centers.count >= 4)
            for color in centers.prefix(4) {
                #expect(abs(color.red * 255 - 231) <= 3 && abs(color.green * 255 - 179) <= 3 && abs(color.blue * 255 - 149) <= 3, "sphere albedo was \(color)")
            }
            // The background has no geometry and stays at the dark placeholder.
            #expect(image.getPixel(x: 6, y: 6).red < 0.1)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func cascadeViewTintsGroundByDistance() async throws {
            let scene = try await Self.makeScene()
            let single = try await scene.render(.cascades)
            let nearSingle = single.getPixel(x: 320, y: 470)
            #expect(nearSingle.red > nearSingle.green * 2 && nearSingle.red > nearSingle.blue * 2, "One cascade covers the ground in cascade zero (red): \(nearSingle)")
            try scene.configure { $0.shadowCascadeCount = 3 }
            let three = try await scene.render(.cascades)
            try Self.expectGolden(three, named: "pbr-spheres-cascades3")
            let near = three.getPixel(x: 320, y: 470)
            let far = three.getPixel(x: 320, y: 275)
            #expect(near.red > near.green * 2, "Nearest ground must stay in cascade zero (red): \(near)")
            #expect(far.green > far.red, "Distant ground must fall into a later cascade (green or blue): \(far)")
            try scene.configure { $0.shadowsEnabled = false }
            let off = try await scene.render(.cascades)
            let gray = off.getPixel(x: 320, y: 470)
            #expect(abs(gray.red - gray.green) < 0.02 && abs(gray.green - gray.blue) < 0.02, "Disabled shadows must show gray, not a cascade color: \(gray)")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func lightCountViewRampsFromBlueTowardRedAsLightsAreAdded() async throws {
            let scene = try await Self.makeScene()
            let single = try await scene.render(.lightCount)
            let one = single.getPixel(x: 320, y: 440)
            #expect(one.blue > 0.8 && one.red < 0.1 && one.green < 0.1, "One directional light is deep blue: \(one)")
            for index in 0..<3 {
                scene.app.main.spawn("Point \(index)") {
                    PointLightComponent(intensity: 2, castShadows: false, range: 30)
                    Transform(position: [Float(index) - 1, 2, -1])
                }
            }
            let crowded = try await scene.render(.lightCount)
            try Self.expectGolden(crowded, named: "pbr-spheres-lightcount-local")
            let four = crowded.getPixel(x: 320, y: 440)
            #expect(four.green > 0.8 && four.blue < one.blue, "Four lights ramp to green: \(four)")
            #expect(four.green > one.green + 0.5)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func noneViewIsStableAcrossViewSwitches() async throws {
            let scene = try await Self.makeScene()
            let first = try await scene.render(.none)
            _ = try await scene.render(.normals)
            let second = try await scene.render(.none)
            let comparison = GoldenFrame.compare(first, second, tolerance: GoldenFrame.activeTolerance)
            #expect(comparison.passes(GoldenFrame.activeTolerance), "Leaving a debug view must restore normal rendering (\(comparison.differingPixels) pixels differ).")
        }
    }
}

typealias Render3DDebugViewGPUTests = Render3DGPUTests.DebugViews

#endif
