#if os(macOS) || os(Windows) || os(Linux)
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// Exposure and bloom settings and chain sizing that need no GPU.
@Suite("3D post-process settings")
struct Render3DPostProcessSettingsTests {
    @Test func defaultsLeaveTheImageUnchanged() {
        let settings = PostProcess3D()
        #expect(settings.exposureEV == 0)
        #expect(settings.exposureScale == 1)
        #expect(!settings.bloom.isEnabled)
        #expect(Environment3D().postProcess == settings)
    }

    @Test func legacyEnvironmentPayloadDecodesWithoutPostProcess() throws {
        let legacy = try JSONEncoder().encode(Environment3D())
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object.removeValue(forKey: "postProcess")
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.postProcess == PostProcess3D())
    }

    @Test func partialPostProcessPayloadFillsDefaults() throws {
        let decoded = try JSONDecoder().decode(PostProcess3D.self, from: Data(#"{"bloom":{"isEnabled":true,"threshold":2}}"#.utf8))
        #expect(decoded.exposureEV == 0)
        #expect(decoded.bloom.isEnabled)
        #expect(decoded.bloom.threshold == 2)
        #expect(decoded.bloom.intensity == Bloom3D().intensity)
        #expect(decoded.bloom.scatter == Bloom3D().scatter)
    }

    @Test func settingsRoundTripThroughTheEnvironment() throws {
        var environment = Environment3D()
        environment.postProcess = PostProcess3D(exposureEV: -1.5, bloom: Bloom3D(isEnabled: true, intensity: 0.7, threshold: 1.4, softKnee: 0.25, scatter: 0.5))
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.postProcess == environment.postProcess)
    }

    @Test func flatAccessorsEditTheNestedSettings() {
        var environment = Environment3D()
        environment.exposureEV = 2
        environment.bloomEnabled = true
        environment.bloomIntensity = 0.4
        environment.bloomThreshold = 3
        #expect(environment.postProcess.exposureEV == 2)
        #expect(environment.postProcess.bloom == Bloom3D(isEnabled: true, intensity: 0.4, threshold: 3))
    }

    @Test func toneMapperDefaultsToAcesAndOldPayloadsKeepIt() throws {
        #expect(PostProcess3D().toneMapper == .aces)
        let decoded = try JSONDecoder().decode(PostProcess3D.self, from: Data(#"{"exposureEV":1}"#.utf8))
        #expect(decoded.toneMapper == .aces)
        #expect(decoded.exposureEV == 1)
    }

    @Test(arguments: ToneMapper3D.allCases)
    func toneMapperRoundTrips(mapper: ToneMapper3D) throws {
        var environment = Environment3D()
        environment.toneMapper = mapper
        #expect(environment.postProcess.toneMapper == mapper)
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.postProcess.toneMapper == mapper)
    }

    @Test func toneMapperRawValuesAndShaderSelectorsAreStable() {
        #expect(ToneMapper3D.allCases.map(\.rawValue) == ["aces", "neutral", "none"])
        // The shader selects the curve by number, and zero must remain the original ACES look.
        #expect(ToneMapper3D.allCases.map(\.shaderMode) == [0, 1, 2])
    }

    @Test func unknownToneMapperNameFailsInsteadOfSilentlyFallingBack() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PostProcess3D.self, from: Data(#"{"toneMapper":"reinhard"}"#.utf8))
        }
    }

    @Test func exposureScaleIsPowerOfTwoLimitedToTenStops() {
        #expect(PostProcess3D(exposureEV: 1).exposureScale == 2)
        #expect(PostProcess3D(exposureEV: -1).exposureScale == 0.5)
        #expect(PostProcess3D(exposureEV: 100).exposureScale == 1024)
        #expect(PostProcess3D(exposureEV: -100).exposureScale == 1.0 / 1024)
        #expect(PostProcess3D(exposureEV: .nan).exposureScale == 1)
        #expect(PostProcess3D(exposureEV: .infinity).exposureScale == 1)
    }

    @Test func bloomSettingsAreSanitizedBeforeReachingTheShader() {
        let wild = Bloom3D(isEnabled: true, intensity: .nan, threshold: -5, softKnee: 9, scatter: .infinity).sanitized
        #expect(wild.intensity == Bloom3D().intensity)
        #expect(wild.threshold == 0)
        #expect(wild.softKnee == 1)
        #expect(wild.scatter == Bloom3D().scatter)
        #expect(Bloom3D(intensity: 100).sanitized.intensity == 4)
    }

    @Test func chainStartsAtHalfResolutionAndStopsAtSixLevelsOrTinyTargets() {
        let large = Bloom3DViews.levelSizes(for: SizeInt(width: 640, height: 480))
        #expect(large.map(\.width) == [320, 160, 80, 40, 20, 10])
        #expect(large.map(\.height) == [240, 120, 60, 30, 15, 8])
        let tiny = Bloom3DViews.levelSizes(for: SizeInt(width: 3, height: 3))
        #expect(tiny == [SizeInt(width: 2, height: 2)])
        #expect(Bloom3DViews.levelSizes(for: SizeInt(width: 1, height: 1)) == [SizeInt(width: 1, height: 1)])
        // A thin target stops once its short side is small, even when the long side is not.
        let thin = Bloom3DViews.levelSizes(for: SizeInt(width: 4096, height: 16))
        #expect(thin.last?.height == 4)
        #expect(thin.count < Bloom3DViews.maximumLevels)
    }
}

extension Render3DGPUTests {
    /// Renders an emissive sphere through the real Metal pipeline to check exposure and bloom.
    ///
    /// Run alone: `ADAENGINE_GOLDEN_METAL=1 swift test --filter Render3DPostProcessGPUTests`.
    @Suite("3D post-process on GPU")
    @MainActor
    struct PostProcess {
        private typealias Scene = Render3DDebugViewGPUTests.Scene

        private static func luminance(_ color: Color) -> Float {
            (color.red + color.green + color.blue) / 3
        }

        /// Bounding box of near-white pixels in the top two fifths of the frame: the emissive sphere's silhouette.
        /// The limit keeps specular highlights on the sphere row below out of the box.
        private static func emitterBounds(in image: Image) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            var bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
            for y in 0..<(image.height * 2 / 5) {
                for x in 0..<image.width where luminance(image.getPixel(x: x, y: y)) > 0.9 {
                    let current = bounds ?? (x, x, y, y)
                    bounds = (min(current.minX, x), max(current.maxX, x), min(current.minY, y), max(current.maxY, y))
                }
            }
            return bounds
        }

        private static func scene(bloom: Bloom3D = Bloom3D(), exposureEV: Float = 0) async throws -> Scene {
            let scene = try await Render3DDebugViewGPUTests.makeScene(emissiveSphere: true)
            try scene.configure {
                $0.postProcess = PostProcess3D(exposureEV: exposureEV, bloom: bloom)
            }
            return scene
        }

        private static func steps(_ left: Color, _ right: Color) -> Float {
            (luminance(left) - luminance(right)) * 255
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func bloomGlowsAroundEmissiveGeometryAndFadesWithDistance() async throws {
            let scene = try await Self.scene()
            let plain = try await scene.render(.none)
            let bounds = try #require(Self.emitterBounds(in: plain), "The emissive sphere must be visible.")
            let row = (bounds.minY + bounds.maxY) / 2

            try scene.configure { $0.postProcess.bloom = Bloom3D(isEnabled: true, intensity: 0.6, threshold: 1, softKnee: 0.5, scatter: 0.7) }
            let glowing = try await scene.render(.none)

            // Brightening just outside the emitter, then less and less farther away, but never darker.
            let lifts = [12, 90, 270].map { offset -> Float in
                let x = min(bounds.maxX + offset, plain.width - 1)
                return Self.steps(glowing.getPixel(x: x, y: row), plain.getPixel(x: x, y: row))
            }
            #expect(lifts[0] > 20, "Pixels just outside the emitter must brighten (lifted by \(lifts[0]) steps).")
            #expect(lifts[0] > lifts[1] && lifts[1] > lifts[2], "Glow must fade with distance: \(lifts)")
            #expect(lifts[2] >= 0 && lifts[2] < lifts[0] * 0.4, "The far field must stay well below the near glow: \(lifts)")
            // Everything lit below the threshold keeps its value: the shaded ground is far from any bloom source.
            let belowThreshold = Self.steps(glowing.getPixel(x: 100, y: 450), plain.getPixel(x: 100, y: 450))
            #expect(belowThreshold >= 0 && belowThreshold < 8, "Low-energy pixels may only gain the faint far-field veil (changed by \(belowThreshold) steps).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func bloomIntensityIsMonotonic() async throws {
            let scene = try await Self.scene()
            let plain = try await scene.render(.none)
            let bounds = try #require(Self.emitterBounds(in: plain))
            let ring = (x: bounds.maxX + 12, y: (bounds.minY + bounds.maxY) / 2)
            var lifts: [Float] = []
            for intensity: Float in [0.15, 0.4, 0.9] {
                try scene.configure { $0.postProcess.bloom = Bloom3D(isEnabled: true, intensity: intensity) }
                lifts.append(Self.steps(try await scene.render(.none).getPixel(x: ring.x, y: ring.y), plain.getPixel(x: ring.x, y: ring.y)))
            }
            #expect(lifts[0] < lifts[1] && lifts[1] < lifts[2], "Glow must grow with intensity: \(lifts)")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func disabledOrZeroIntensityBloomLeavesTheFrameIdentical() async throws {
            let scene = try await Self.scene()
            let baseline = try await scene.render(.none)
            // Non-default values that must be ignored while bloom is off.
            try scene.configure { $0.postProcess.bloom = Bloom3D(isEnabled: false, intensity: 2, threshold: 0, softKnee: 1, scatter: 1) }
            let off = try await scene.render(.none)
            #expect(GoldenFrame.compare(baseline, off, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            try scene.configure { $0.postProcess.bloom = Bloom3D(isEnabled: true, intensity: 0) }
            let zero = try await scene.render(.none)
            #expect(GoldenFrame.compare(baseline, zero, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func exposureScalesBrightnessInBothDirections() async throws {
            let scene = try await Self.scene()
            let normal = try await scene.render(.none)
            try scene.configure { $0.postProcess.exposureEV = 1 }
            let brighter = try await scene.render(.none)
            try scene.configure { $0.postProcess.exposureEV = -1 }
            let darker = try await scene.render(.none)
            for point in [(320, 440), (200, 300)] {
                let base = Self.luminance(normal.getPixel(x: point.0, y: point.1))
                #expect(Self.luminance(brighter.getPixel(x: point.0, y: point.1)) > base + 8 / 255)
                #expect(Self.luminance(darker.getPixel(x: point.0, y: point.1)) < base - 8 / 255)
            }
        }

        private static let probes = [(320, 440), (100, 450), (560, 430), (60, 300)]

        /// The composite shader tone maps the direct and FXAA paths and the temporal shader tone maps the upscaled
        /// path. Both include one shared transform, so every operator must give the same picture on both. The
        /// temporal path exists only on Metal.
        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled && GoldenFrame.activeBackend != .saga), arguments: ToneMapper3D.allCases)
        func operatorsAgreeBetweenCompositeAndTemporalShaders(mapper: ToneMapper3D) async throws {
            let direct = try await Render3DDebugViewGPUTests.makeScene(emissiveSphere: true)
            try direct.configure { $0.postProcess.toneMapper = mapper }
            let directImage = try await direct.render(.none)
            let temporal = try await Render3DDebugViewGPUTests.makeScene(emissiveSphere: true, temporalRenderScale: 1)
            try temporal.configure { $0.postProcess.toneMapper = mapper }
            let temporalImage = try await temporal.render(.none, frames: 10)
            for (x, y) in Self.probes {
                let difference = abs(Self.steps(directImage.getPixel(x: x, y: y), temporalImage.getPixel(x: x, y: y)))
                #expect(difference <= 4, "\(mapper) at (\(x), \(y)): composite and temporal shaders differ by \(difference) steps.")
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func operatorsShapeTheImageAsDocumented() async throws {
            let scene = try await Self.scene()
            var images: [ToneMapper3D: Image] = [:]
            for mapper in ToneMapper3D.allCases {
                try scene.configure { $0.postProcess.toneMapper = mapper }
                images[mapper] = try await scene.render(.none)
            }
            let aces = try #require(images[.aces]), neutral = try #require(images[.neutral]), none = try #require(images[.none])
            let plain = try await Self.scene().render(.none)
            #expect(GoldenFrame.compare(aces, plain, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance), "ACES must stay the default look.")
            let bounds = try #require(Self.emitterBounds(in: aces))
            for (name, image) in [("aces", aces), ("neutral", neutral), ("none", none)] {
                let point = ((bounds.minX + bounds.maxX) / 2, (bounds.minY + bounds.maxY) / 2)
                let center = Self.luminance(image.getPixel(x: point.0, y: point.1))
                #expect(center > 0.9, "\(name): an overbright emitter must read as near white at \(point) (bounds \(bounds), color \(image.getPixel(x: point.0, y: point.1))).")
            }
            // Neutral keeps mid-tones close to the untouched linear values; ACES lifts them away from that.
            for (x, y) in Self.probes.prefix(2) {
                let reference = none.getPixel(x: x, y: y)
                let neutralDistance = abs(Self.steps(neutral.getPixel(x: x, y: y), reference))
                let acesDistance = abs(Self.steps(aces.getPixel(x: x, y: y), reference))
                #expect(neutralDistance < acesDistance, "At (\(x), \(y)) neutral should stay nearer to no curve than ACES (\(neutralDistance) vs \(acesDistance)).")
                #expect(acesDistance > 4)
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func toneMappersMatchGoldenFrames() async throws {
            let scene = try await Self.scene()
            for mapper in [ToneMapper3D.neutral, .none] {
                try scene.configure { $0.postProcess.toneMapper = mapper }
                let image = try await scene.render(.none)
                let name = "emissive-tonemap-\(mapper.rawValue)"
                switch try GoldenFrame.check(image, name: name) {
                case .recorded, .matched:
                    break
                case .missingReference(let actual):
                    Issue.record("No golden frame for \(name); record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
                case let .mismatched(comparison, actual, difference):
                    Issue.record("\(name) differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
                }
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func chainIsAllocatedOnlyWhileBloomIsEnabled() async throws {
            let scene = try await Self.scene()
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            // The resource is a value type, so read it again after each frame.
            func views() throws -> Bloom3DViews { try #require(renderWorld.getResource(Bloom3DViews.self)) }
            _ = try await scene.render(.none)
            #expect(try views().levelCount(view: scene.camera.id) == 0, "Disabled bloom must not allocate a chain.")
            try scene.configure { $0.postProcess.bloom = Bloom3D(isEnabled: true) }
            _ = try await scene.render(.none)
            #expect(try views().levelCount(view: scene.camera.id) == 6)
            #expect(try views().output(view: scene.camera.id)?.size == SizeInt(width: 320, height: 240))
            try scene.configure { $0.postProcess.bloom.isEnabled = false }
            _ = try await scene.render(.none)
            #expect(try views().levelCount(view: scene.camera.id) == 0, "Turning bloom off must release its textures.")
        }

        enum Path: String, CaseIterable, CustomStringConvertible {
            case direct, fxaa, temporal
            var description: String { rawValue }

            /// Temporal upscaling needs MetalFX, so WebGPU renders only the direct and FXAA paths.
            nonisolated static var supported: [Path] {
                GoldenFrame.activeBackend == .saga ? [.direct, .fxaa] : allCases
            }
        }

        /// Bloom and exposure run in the environment composite, but tone mapping happens in different shaders
        /// depending on how the frame is presented: directly, through FXAA, or through the temporal resolve.
        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled), arguments: Path.supported)
        func bloomAndExposureWorkOnEveryPresentationPath(path: Path) async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(
                emissiveSphere: true,
                antiAliasing: path == .fxaa ? .fxaa : .none,
                temporalRenderScale: path == .temporal ? 1 : nil
            )
            let frames = path == .temporal ? 10 : 4
            let plain = try await scene.render(.none, frames: frames)
            let bounds = try #require(Self.emitterBounds(in: plain), "\(path): the emissive sphere must be visible.")
            let row = (bounds.minY + bounds.maxY) / 2
            let x = min(bounds.maxX + 12, plain.width - 1)

            try scene.configure { $0.postProcess.bloom = Bloom3D(isEnabled: true, intensity: 0.6) }
            let glowing = try await scene.render(.none, frames: frames)
            let lift = Self.steps(glowing.getPixel(x: x, y: row), plain.getPixel(x: x, y: row))
            #expect(lift > 12, "\(path): bloom must brighten pixels beside the emitter (lifted by \(lift) steps).")

            try scene.configure {
                $0.postProcess.bloom.isEnabled = false
                $0.postProcess.exposureEV = 1
            }
            let brighter = try await scene.render(.none, frames: frames)
            try scene.configure { $0.postProcess.exposureEV = -1 }
            let darker = try await scene.render(.none, frames: frames)
            let base = Self.luminance(plain.getPixel(x: 320, y: 440))
            #expect(Self.luminance(brighter.getPixel(x: 320, y: 440)) > base + 8 / 255, "\(path): +1 EV must brighten the ground.")
            #expect(Self.luminance(darker.getPixel(x: 320, y: 440)) < base - 8 / 255, "\(path): -1 EV must darken the ground.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func bloomAndExposureMatchGoldenFrames() async throws {
            let scene = try await Self.scene()
            var frames: [(name: String, image: Image)] = []
            let cases: [(name: String, settings: PostProcess3D)] = [
                ("emissive-plain", PostProcess3D()),
                ("emissive-bloom", PostProcess3D(bloom: Bloom3D(isEnabled: true, intensity: 0.5))),
                ("emissive-bloom-exposure-minus1", PostProcess3D(exposureEV: -1, bloom: Bloom3D(isEnabled: true, intensity: 0.5, threshold: 0.5))),
                ("emissive-exposure-plus1", PostProcess3D(exposureEV: 1)),
            ]
            for (name, settings) in cases {
                try scene.configure { $0.postProcess = settings }
                frames.append((name, try await scene.render(.none)))
            }
            for (name, image) in frames {
                switch try GoldenFrame.check(image, name: name) {
                case .recorded, .matched:
                    break
                case .missingReference(let actual):
                    Issue.record("No golden frame for \(name); record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
                case let .mismatched(comparison, actual, difference):
                    Issue.record("\(name) differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
                }
            }
        }
    }
}

typealias Render3DPostProcessGPUTests = Render3DGPUTests.PostProcess

#endif
