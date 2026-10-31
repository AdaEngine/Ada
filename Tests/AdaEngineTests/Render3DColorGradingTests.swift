#if os(macOS) || os(Windows) || os(Linux)
import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// Vignette and color grading settings that need no GPU.
@Suite("3D color grading settings")
struct Render3DColorGradingSettingsTests {
    @Test func defaultsAreNeutral() {
        let settings = PostProcess3D()
        #expect(settings.vignette.intensity == 0)
        #expect(settings.colorGrading.saturation == 1)
        #expect(settings.colorGrading.contrast == 1)
        #expect(settings.colorGrading.lut == nil)
        #expect(settings.colorGrading.activeLUT == nil)
    }

    @Test func olderPayloadsDecodeToNeutralGrading() throws {
        let decoded = try JSONDecoder().decode(PostProcess3D.self, from: Data(#"{"exposureEV":1,"toneMapper":"neutral"}"#.utf8))
        #expect(decoded.vignette == Vignette3D())
        #expect(decoded.colorGrading == ColorGrading3D())
        #expect(decoded.toneMapper == .neutral)
    }

    @Test func partialPayloadsFillTheRestWithDefaults() throws {
        let vignette = try JSONDecoder().decode(Vignette3D.self, from: Data(#"{"intensity":0.6}"#.utf8))
        #expect(vignette.intensity == 0.6)
        #expect(vignette.radius == Vignette3D().radius)
        let grading = try JSONDecoder().decode(ColorGrading3D.self, from: Data(#"{"saturation":0.5}"#.utf8))
        #expect(grading.saturation == 0.5)
        #expect(grading.contrast == 1)
        #expect(grading.lutIntensity == 1)
    }

    @Test func settingsRoundTripThroughTheEnvironment() throws {
        var environment = Environment3D()
        environment.postProcess.vignette = Vignette3D(intensity: 0.5, radius: 0.6, smoothness: 0.3)
        environment.postProcess.colorGrading = ColorGrading3D(saturation: 0.7, contrast: 1.4, lutIntensity: 0.25)
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.postProcess.vignette == environment.postProcess.vignette)
        #expect(decoded.postProcess.colorGrading == environment.postProcess.colorGrading)
    }

    @Test func flatAccessorsEditTheNestedSettings() {
        var environment = Environment3D()
        environment.vignetteIntensity = 0.4
        environment.saturation = 0.8
        environment.contrast = 1.2
        #expect(environment.postProcess.vignette.intensity == 0.4)
        #expect(environment.postProcess.colorGrading.saturation == 0.8)
        #expect(environment.postProcess.colorGrading.contrast == 1.2)
    }

    @Test func wildValuesAreClampedBeforeReachingTheShader() {
        let vignette = Vignette3D(intensity: .nan, radius: -3, smoothness: 0).sanitized
        #expect(vignette.intensity == 0)
        #expect(vignette.radius == 0)
        #expect(vignette.smoothness == 0.01)
        let grading = ColorGrading3D(saturation: .infinity, contrast: 0, lutIntensity: 9).sanitized
        #expect(grading.saturation == 1)
        #expect(grading.contrast == 0.1)
        #expect(grading.lutIntensity == 1)
    }
}

extension Render3DGPUTests {
    /// Renders vignette, saturation, contrast and LUT grading through the real Metal pipeline.
    ///
    /// Run alone: `ADAENGINE_GOLDEN_METAL=1 swift test --filter Render3DColorGradingGPUTests`.
    @Suite("3D color grading on GPU")
    @MainActor
    struct ColorGrading {
        private typealias Scene = Render3DDebugViewGPUTests.Scene

        /// Ground, a sphere highlight, a shaded sphere side and the sky: bright, dark and colored regions.
        private static let probes = [(320, 440), (100, 450), (150, 230), (200, 215), (490, 225), (320, 60)]

        private static func steps(_ left: Float, _ right: Float) -> Float { abs(left - right) * 255 }

        private static func channels(_ color: Color) -> [Float] { [color.red, color.green, color.blue] }

        private static func luminance(_ color: Color) -> Float { (color.red + color.green + color.blue) / 3 }

        /// Identity strip LUT with `size` tiles: red along x, green down the rows, blue by tile.
        /// `transform` maps the identity color to the stored color (for example inversion).
        private static func lutTexture(size: Int = 16, transform: (Vector3) -> Vector3 = { $0 }) -> Texture2D {
            var bytes = [UInt8](repeating: 255, count: size * size * size * 4)
            let scale = Float(size - 1)
            for tile in 0..<size {
                for row in 0..<size {
                    for column in 0..<size {
                        let color = transform(Vector3(Float(column) / scale, Float(row) / scale, Float(tile) / scale))
                        let offset = (row * size * size + tile * size + column) * 4
                        bytes[offset] = UInt8((min(max(color.x, 0), 1) * 255).rounded())
                        bytes[offset + 1] = UInt8((min(max(color.y, 0), 1) * 255).rounded())
                        bytes[offset + 2] = UInt8((min(max(color.z, 0), 1) * 255).rounded())
                    }
                }
            }
            return Texture2D(image: Image(width: size * size, height: size, data: Data(bytes), format: .rgba8))
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

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func vignetteDarkensCornersAndLeavesTheCenterAlone() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let plain = try await scene.render(.none)
            try scene.configure { $0.postProcess.vignette = Vignette3D(intensity: 0.8, radius: 0.5, smoothness: 0.5) }
            let vignetted = try await scene.render(.none)
            try Self.expectGolden(vignetted, named: "pbr-spheres-vignette")
            let centerChange = Self.steps(Self.luminance(vignetted.getPixel(x: 320, y: 240)), Self.luminance(plain.getPixel(x: 320, y: 240)))
            #expect(centerChange <= 3, "The center must stay untouched (changed by \(centerChange) steps).")
            for (x, y) in [(4, 4), (635, 4), (4, 475), (635, 475)] {
                let ratio = Self.luminance(vignetted.getPixel(x: x, y: y)) / max(Self.luminance(plain.getPixel(x: x, y: y)), 0.001)
                #expect(ratio < 0.5, "Corner (\(x), \(y)) must darken strongly (kept \(ratio) of its brightness).")
            }
            // A wider clear radius darkens a mid-edge pixel less.
            try scene.configure { $0.postProcess.vignette = Vignette3D(intensity: 0.8, radius: 0.95, smoothness: 0.5) }
            let wide = try await scene.render(.none)
            let edge = (10, 240)
            #expect(Self.luminance(wide.getPixel(x: edge.0, y: edge.1)) > Self.luminance(vignetted.getPixel(x: edge.0, y: edge.1)))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func saturationScalesColorfulnessAndZeroGivesGray() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let plain = try await scene.render(.none)
            try scene.configure { $0.saturation = 0 }
            let gray = try await scene.render(.none)
            for (x, y) in Self.probes {
                let values = Self.channels(gray.getPixel(x: x, y: y))
                #expect((values.max() ?? 0) - (values.min() ?? 0) <= 3 / 255, "(\(x), \(y)) must be neutral gray, got \(values)")
            }
            try scene.configure { $0.saturation = 1.8 }
            let vivid = try await scene.render(.none)
            func chroma(_ image: Image, _ x: Int, _ y: Int) -> Float {
                let values = Self.channels(image.getPixel(x: x, y: y))
                return (values.max() ?? 0) - (values.min() ?? 0)
            }
            #expect(chroma(vivid, 150, 230) > chroma(plain, 150, 230) + 0.02, "The orange sphere must become more colorful.")
            #expect(chroma(vivid, 320, 60) > chroma(plain, 320, 60), "The sky must become more colorful.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func contrastSpreadsBrightAndDarkAwayFromMidGray() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let plain = try await scene.render(.none)
            // A lit highlight and the sphere's shaded side.
            let bright = (200, 215), dark = (490, 225)
            func spread(_ image: Image) -> Float {
                Self.luminance(image.getPixel(x: bright.0, y: bright.1)) - Self.luminance(image.getPixel(x: dark.0, y: dark.1))
            }
            try scene.configure { $0.contrast = 1.6 }
            let harsh = try await scene.render(.none)
            try scene.configure { $0.contrast = 0.5 }
            let soft = try await scene.render(.none)
            #expect(spread(harsh) > spread(plain) + 0.03, "Contrast above one must widen the bright to dark spread.")
            #expect(spread(soft) < spread(plain) - 0.03, "Contrast below one must narrow it.")
            try Self.expectGolden(harsh, named: "pbr-spheres-contrast")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled), arguments: Render3DPostProcessGPUTests.Path.supported)
        func curvesAreAppliedAfterToneMapping(path: Render3DPostProcessGPUTests.Path) async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(
                antiAliasing: path == .fxaa ? .fxaa : .none,
                temporalRenderScale: path == .temporal ? 1 : nil
            )
            let frames = path == .temporal ? 16 : 4
            let plain = try await scene.render(.none, frames: frames)
            let inverse = ColorCurves3D(master: ColorCurve3D(points: [.init(0, 1), .init(1, 0)]))
            try scene.configure { $0.postProcess.colorGrading = ColorGrading3D(correctionMode: .curves, curves: inverse) }
            let corrected = try await scene.render(.none, frames: frames)
            try scene.configure { $0.colorCorrectionStrength = 0.5 }
            let blended = try await scene.render(.none, frames: frames)
            for (x, y) in Self.probes {
                let base = Self.channels(plain.getPixel(x: x, y: y))
                for (index, value) in Self.channels(corrected.getPixel(x: x, y: y)).enumerated() {
                    #expect(Self.steps(value, 1 - base[index]) <= 8, "\(path): curves must invert the display color.")
                }
                for value in Self.channels(blended.getPixel(x: x, y: y)) {
                    #expect(Self.steps(value, 0.5) <= 8, "\(path): half-strength inversion must give gray.")
                }
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled), arguments: Render3DPostProcessGPUTests.Path.supported)
        func lutIsAppliedAfterToneMappingOnEveryPath(path: Render3DPostProcessGPUTests.Path) async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(
                antiAliasing: path == .fxaa ? .fxaa : .none,
                temporalRenderScale: path == .temporal ? 1 : nil
            )
            // Temporal jitter repeats every eight frames, so renders of equal length land on the same phase.
            let frames = path == .temporal ? 16 : 4
            let plain = try await scene.render(.none, frames: frames)

            // No LUT, and a LUT with zero intensity, change nothing. Direct and FXAA frames repeat exactly. The
            // temporal resolve keeps accumulating history, so it is held to the drift two untouched renders show.
            let repeated = try await scene.render(.none, frames: frames)
            let drift = GoldenFrame.compare(plain, repeated, tolerance: GoldenFrame.activeTolerance)
            try scene.configure { $0.postProcess.colorGrading = ColorGrading3D(lutIntensity: 0) }
            let off = try await scene.render(.none, frames: frames)
            let offDifference = GoldenFrame.compare(plain, off, tolerance: GoldenFrame.activeTolerance)
            if path == .temporal {
                #expect(
                    offDifference.differingPixels <= drift.differingPixels * 2 + 200,
                    "temporal: a disabled LUT differs in \(offDifference.differingPixels) pixels against \(drift.differingPixels) of natural drift."
                )
            } else {
                #expect(
                    drift.passes(GoldenFrame.activeTolerance) && offDifference.passes(GoldenFrame.activeTolerance),
                    "\(path): a disabled LUT must leave the frame identical (\(offDifference.differingPixels) pixels differ)."
                )
            }

            // The temporal resolve is not exactly repeatable at a bright highlight: two untouched renders already differ by a
            // few steps there, and by a different amount from run to run. Its checks allow that measured drift on top of
            // the LUT's own tolerance, so they test the LUT and not the noise floor.
            func noise(_ x: Int, _ y: Int, _ channel: Int) -> Float {
                guard path == .temporal else { return 0 }
                return Self.steps(Self.channels(plain.getPixel(x: x, y: y))[channel], Self.channels(repeated.getPixel(x: x, y: y))[channel])
            }

            let identity = AssetHandle(Self.lutTexture())
            try scene.configure { $0.postProcess.colorGrading = ColorGrading3D(lut: identity) }
            let same = try await scene.render(.none, frames: frames)
            for (x, y) in Self.probes {
                for (channel, (left, right)) in zip(Self.channels(same.getPixel(x: x, y: y)), Self.channels(plain.getPixel(x: x, y: y))).enumerated() {
                    let allowed = 3 + noise(x, y, channel)
                    #expect(Self.steps(left, right) <= allowed, "\(path): identity LUT changed (\(x), \(y)) channel \(channel) by \(Self.steps(left, right)) steps (allowed \(allowed)).")
                }
            }

            let invert = AssetHandle(Self.lutTexture { Vector3(1 - $0.x, 1 - $0.y, 1 - $0.z) })
            try scene.configure { $0.postProcess.colorGrading = ColorGrading3D(lut: invert) }
            let inverted = try await scene.render(.none, frames: frames)
            try scene.configure { $0.postProcess.colorGrading = ColorGrading3D(lut: invert, lutIntensity: 0.5) }
            let halfway = try await scene.render(.none, frames: frames)
            for (x, y) in Self.probes {
                let base = Self.channels(plain.getPixel(x: x, y: y))
                for (index, value) in Self.channels(inverted.getPixel(x: x, y: y)).enumerated() {
                    #expect(Self.steps(value, 1 - base[index]) <= 5 + noise(x, y, index), "\(path): inverted LUT at (\(x), \(y)) channel \(index): \(value * 255) vs \((1 - base[index]) * 255).")
                }
                // Halfway between a color and its inverse is mid gray whatever the color.
                for value in Self.channels(halfway.getPixel(x: x, y: y)) {
                    #expect(Self.steps(value, 0.5) <= 6, "\(path): half-intensity inversion at (\(x), \(y)) should be mid gray, got \(value * 255).")
                }
            }
            if path == .direct {
                try Self.expectGolden(inverted, named: "pbr-spheres-lut-inverted")
            }
        }
    }
}

typealias Render3DColorGradingGPUTests = Render3DGPUTests.ColorGrading

#endif
