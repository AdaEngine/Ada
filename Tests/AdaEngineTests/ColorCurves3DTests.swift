import AdaApp
import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import Foundation
import Testing

@testable import AdaCorePipelines

@Suite("Color correction curves")
struct ColorCurves3DTests {
    @Test func neutralCurveAndInversion() {
        let identity = ColorCurve3D()
        let invert = ColorCurve3D(points: [.init(0, 1), .init(1, 0)])
        for step in 0...100 {
            let value = Float(step) / 100
            #expect(abs(identity.evaluate(at: value) - value) < 0.00001)
            #expect(abs(invert.evaluate(at: value) - (1 - value)) < 0.00001)
        }
    }

    @Test func smoothCurvePassesThroughPointsWithoutOvershoot() {
        let curve = ColorCurve3D(points: [.init(0, 0), .init(0.2, 0.05), .init(0.55, 0.8), .init(1, 1)])
        for point in curve.points { #expect(abs(curve.evaluate(at: point.input) - point.output) < 0.00001) }
        let samples = curve.sampledValues(count: 1001)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(samples.allSatisfy { $0.isFinite && (0...1).contains($0) })
        let peak = ColorCurve3D(points: [.init(0, 0), .init(0.5, 1), .init(1, 0)])
        #expect(peak.sampledValues().allSatisfy { (0...1).contains($0) })
    }

    @Test func malformedCurvesBecomeFiniteAndOrdered() {
        let curve = ColorCurve3D(points: [.init(.nan, 0), .init(1, .infinity), .init(0.5, 0.2), .init(-3, -2), .init(0.5, 0.8)]).sanitized
        #expect(curve.points == [.init(0, 0), .init(0.5, 0.8), .init(1, 1)])
        #expect(ColorCurve3D(points: []).sanitized == ColorCurve3D())
        #expect(curve.evaluate(at: .nan).isFinite)
        #expect(curve.evaluate(at: -1) == 0)
        #expect(curve.evaluate(at: 2) == 1)
        let crowded = ColorCurve3D(points: [.init(0, 0), .init(.leastNonzeroMagnitude, 1), .init(1, 1)])
        #expect(crowded.sampledValues().allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(crowded.sanitized.points.count == 2)
    }

    @Test func newSettingsRoundTripAndOldLUTSettingsKeepTheirMode() throws {
        let old = try JSONDecoder().decode(ColorGrading3D.self, from: Data(#"{"lutIntensity":0.4}"#.utf8))
        #expect(old.correctionMode == .lut)
        #expect(old.curves == ColorCurves3D())
        var environment = Environment3D()
        environment.postProcess.colorGrading.correctionMode = .curves
        environment.postProcess.colorGrading.curves.green = ColorCurve3D(points: [.init(0, 0.1), .init(1, 0.8)])
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.postProcess.colorGrading == environment.postProcess.colorGrading)
        let partial = try JSONDecoder().decode(ColorCurves3D.self, from: Data(#"{"red":{"points":[{"input":0,"output":1},{"input":1,"output":0}]}}"#.utf8))
        #expect(partial.master == ColorCurve3D())
        #expect(partial.red.evaluate(at: 0) == 1)
    }

    @Test func bakedStripUsesMasterThenIndividualChannels() {
        let invert = ColorCurve3D(points: [.init(0, 1), .init(1, 0)])
        let curves = ColorCurves3D(master: invert, red: invert, green: ColorCurve3D(points: [.init(0, 0.25), .init(1, 0.25)]))
        let image = curves.makeLUTImage()
        #expect(image.width == 1024 && image.height == 32)
        let pixel = image.getPixel(x: 7 * 32 + 12, y: 20)
        #expect(abs(pixel.red - 12.0 / 31) <= 1.0 / 255)
        #expect(abs(pixel.green - 0.25) <= 1.0 / 255)
        #expect(abs(pixel.blue - (1 - 7.0 / 31)) <= 1.0 / 255)
    }
}

@MainActor
@Suite("Color correction texture ownership", .serialized, .enabled(if: !Render3DDebugViewGPUTests.enabled))
struct ColorCorrection3DResourceTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
    }

    @Test func textureIsReusedUntilTheCurveChangesAndReleasedWhenDisabled() throws {
        let view = Entity().id
        var cache = ColorCorrection3DViews()
        var settings = ColorGrading3D(correctionMode: .curves)
        cache.prepare(settings, view: view)
        #expect(cache.resolve(settings, view: view) == nil)
        settings.curves.master = ColorCurve3D(points: [.init(0, 1), .init(1, 0)])
        cache.prepare(settings, view: view)
        let first = try #require(cache.resolve(settings, view: view)?.texture)
        settings.lutIntensity = 0.4
        cache.prepare(settings, view: view)
        #expect(cache.resolve(settings, view: view)?.texture === first)
        #expect(cache.resolve(settings, view: view)?.intensity == 0.4)
        settings.curves.red = ColorCurve3D(points: [.init(0, 0.2), .init(1, 1)])
        cache.prepare(settings, view: view)
        #expect(cache.resolve(settings, view: view)?.texture !== first)
        settings.correctionMode = .disabled
        cache.prepare(settings, view: view)
        #expect(cache.resolve(settings, view: view) == nil)
        #expect(cache.entries.isEmpty)
    }

    @Test func malformedStripAndDisabledLUTAreIgnored() {
        let invalid = AssetHandle(Texture2D(image: Image(width: 32, height: 32, color: .white)))
        #expect(ColorGrading3D(lut: invalid).activeLUT == nil)
        let valid = AssetHandle(Texture2D(image: Image(width: 256, height: 16, color: .white)))
        #expect(ColorGrading3D(lut: valid).activeLUT != nil)
        #expect(ColorGrading3D(lut: valid, correctionMode: .disabled).activeLUT == nil)
        #expect(ColorGrading3D(lut: valid, correctionMode: .curves).activeLUT == nil)
    }
}
