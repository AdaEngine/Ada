#if os(macOS) || os(Windows) || os(Linux)
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// Fog settings that need no GPU.
@Suite("3D fog settings")
struct Render3DFogSettingsTests {
    @Test func defaultsAreOff() {
        let fog = Fog3D()
        #expect(!fog.isEnabled && !fog.changesImage)
        #expect(Environment3D().fog == fog)
    }

    @Test func olderPayloadsDecodeWithoutFog() throws {
        let environment = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(environment.fog == Fog3D())
        let partial = try JSONDecoder().decode(Fog3D.self, from: Data(#"{"isEnabled":true,"density":0.1}"#.utf8))
        #expect(partial.isEnabled && partial.density == 0.1 && partial.maximumOpacity == Fog3D().maximumOpacity)
    }

    @Test func settingsRoundTripAndFlatAccessors() throws {
        var environment = Environment3D()
        environment.fogEnabled = true
        environment.fogDensity = 0.3
        environment.fog.heightFalloff = 0.5
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.fog == environment.fog)
        #expect(decoded.fogEnabled && decoded.fogDensity == 0.3)
    }

    @Test func wildValuesAreClamped() {
        let wild = Fog3D(isEnabled: true, density: .nan, heightFalloff: -4, startDistance: -1, maximumOpacity: 7, skyInfluence: 2, sunExponent: 0).sanitized
        #expect(wild.density == Fog3D().density)
        #expect(wild.heightFalloff == 0 && wild.startDistance == 0)
        #expect(wild.maximumOpacity == 1 && wild.skyInfluence == 1 && wild.sunExponent == 1)
    }

    @Test func volumetricDefaultsAreOffAndOlderPayloadsDecode() throws {
        #expect(!VolumetricFog3D().isEnabled && !Fog3D(isEnabled: true).volumetricActive)
        let decoded = try JSONDecoder().decode(Fog3D.self, from: Data(#"{"isEnabled":true}"#.utf8))
        #expect(decoded.volumetric == VolumetricFog3D())
        let partial = try JSONDecoder().decode(Fog3D.self, from: Data(#"{"volumetric":{"isEnabled":true,"steps":40}}"#.utf8))
        #expect(partial.volumetric.isEnabled && partial.volumetric.steps == 40)
    }

    @Test func volumetricRequiresFogAndClampsValues() {
        var fog = Fog3D(isEnabled: false, volumetric: VolumetricFog3D(isEnabled: true))
        #expect(!fog.volumetricActive, "Light shafts need the fog medium.")
        fog.isEnabled = true
        #expect(fog.volumetricActive)
        fog.volumetric.intensity = 0
        #expect(!fog.volumetricActive)
        let wild = VolumetricFog3D(isEnabled: true, intensity: .nan, anisotropy: 5, steps: 1000, maxDistance: -3).sanitized
        #expect(wild.intensity == VolumetricFog3D().intensity && wild.anisotropy == 0.95)
        #expect(wild.steps == 64 && wild.maxDistance == 1)
        #expect(VolumetricFog3D(steps: -2).sanitized.steps == 4)
    }

    @Test func settingsThatCannotChangeTheImageAreNotCountedAsAnEffect() {
        #expect(!Fog3D(isEnabled: false).changesImage)
        #expect(!Fog3D(isEnabled: true, density: 0).changesImage)
        #expect(!Fog3D(isEnabled: true, maximumOpacity: 0).changesImage)
        #expect(Fog3D(isEnabled: true).changesImage)
    }
}

extension Render3DGPUTests {
    /// Renders fog through the real composite pass.
    ///
    /// Run alone: `ADAENGINE_GOLDEN_SAGA=1 swift test --filter Render3DGPUTests/Fog`.
    @Suite("3D fog on GPU")
    @MainActor
    struct Fog {
        private static let fogColor = Color(red: 1, green: 0, blue: 0)
        /// A pixel on the first sphere's lit side, 3.4 units from the camera.
        private static let sphere = (x: 100, y: 215)

        /// How far the pixel is from the fog color, as the red channel's lead over blue.
        private static func redness(_ image: Image) -> Float {
            let pixel = image.getPixel(x: sphere.x, y: sphere.y)
            return pixel.red - pixel.blue
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func fogOutOfReachChangesNothing() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let baseline = try await scene.render(.none)
            let unreachable: [Fog3D] = [
                Fog3D(isEnabled: false, color: Self.fogColor, density: 2),
                Fog3D(isEnabled: true, color: Self.fogColor, density: 2, startDistance: 50),
                Fog3D(isEnabled: true, color: Self.fogColor, density: 2, heightFalloff: 10, baseHeight: -50),
            ]
            for fog in unreachable {
                try scene.configure { $0.fog = fog }
                let image = try await scene.render(.none)
                #expect(GoldenFrame.compare(baseline, image, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func denserFogPullsSurfacesTowardTheFogColor() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let clear = Self.redness(try await scene.render(.none))
            try scene.configure { $0.fog = Fog3D(isEnabled: true, color: Self.fogColor, density: 0.1) }
            let light = Self.redness(try await scene.render(.none))
            try scene.configure { $0.fog.density = 1 }
            let dense = Self.redness(try await scene.render(.none))
            #expect(light > clear && dense > light, "Fog must tint monotonically with density (\(clear), \(light), \(dense)).")
            try scene.configure { $0.fog.maximumOpacity = 0.2 }
            let capped = Self.redness(try await scene.render(.none))
            #expect(capped < dense, "A lower maximum opacity must leave more of the surface (\(capped) vs \(dense)).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func heightFogThinsAboveItsBaseHeight() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            // The camera and spheres sit near y = 0.5, so a base at 0.5 gives full density and one far above gives none.
            try scene.configure { $0.fog = Fog3D(isEnabled: true, color: Self.fogColor, density: 0.5, heightFalloff: 1, baseHeight: 0.5) }
            let inside = Self.redness(try await scene.render(.none))
            try scene.configure { $0.fog.baseHeight = -8 }
            let above = Self.redness(try await scene.render(.none))
            #expect(inside > above, "Fog must be thinner when the camera is above its base (\(inside) vs \(above)).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func fogMatchesGoldenFrames() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(farMarker: true)
            try scene.configure {
                $0.fog = Fog3D(
                    isEnabled: true,
                    color: Color(red: 0.62, green: 0.72, blue: 0.82),
                    density: 0.12,
                    heightFalloff: 0.3,
                    baseHeight: 0,
                    startDistance: 1,
                    maximumOpacity: 0.9,
                    skyInfluence: 0.5,
                    sunInscattering: 0.4,
                    sunExponent: 6
                )
            }
            switch try GoldenFrame.check(try await scene.render(.none), name: "pbr-spheres-fog") {
            case .recorded, .matched:
                break
            case .missingReference(let actual):
                Issue.record("No golden frame for pbr-spheres-fog; record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
            case let .mismatched(comparison, actual, difference):
                Issue.record("pbr-spheres-fog differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
            }
        }

        private static func meanLuminance(_ image: Image) -> Float {
            var sum: Float = 0
            for y in stride(from: 0, to: 480, by: 4) {
                for x in stride(from: 0, to: 640, by: 4) {
                    let pixel = image.getPixel(x: x, y: y)
                    sum += (pixel.red + pixel.green + pixel.blue) / 3
                }
            }
            return sum / Float(120 * 160)
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func lightShaftsAddSunLightAndReleaseTheirTexture() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(farMarker: true)
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            func shafts() throws -> VolumetricFog3DViews { try #require(renderWorld.getResource(VolumetricFog3DViews.self)) }
            let fog = Fog3D(isEnabled: true, color: Color(red: 0.2, green: 0.2, blue: 0.2), density: 0.15, maximumOpacity: 0.6)
            try scene.configure { $0.fog = fog }
            let plain = try await scene.render(.none)
            #expect(try shafts().output(view: scene.camera.id) == nil)
            try scene.configure { $0.fog.volumetric = VolumetricFog3D(isEnabled: true, intensity: 4, anisotropy: 0, steps: 24, maxDistance: 20) }
            let lit = try await scene.render(.none)
            #expect(try shafts().output(view: scene.camera.id) != nil)
            #expect(Self.meanLuminance(lit) > Self.meanLuminance(plain), "Light shafts must add sun light to the fog.")
            try scene.configure { $0.fog.volumetric.isEnabled = false }
            let released = try await scene.render(.none)
            #expect(try shafts().output(view: scene.camera.id) == nil, "Turning the effect off must release the texture.")
            #expect(GoldenFrame.compare(plain, released, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func shadowsCarveTheLightShafts() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(farMarker: true)
            let fog = Fog3D(
                isEnabled: true,
                color: Color(red: 0.2, green: 0.2, blue: 0.2),
                density: 0.15,
                maximumOpacity: 0.6,
                volumetric: VolumetricFog3D(isEnabled: true, intensity: 4, anisotropy: 0, steps: 32, maxDistance: 20)
            )
            try scene.configure { $0.fog = fog; $0.shadowsEnabled = true }
            let shadowed = try await scene.render(.none)
            try scene.configure { $0.shadowsEnabled = false }
            let unshadowed = try await scene.render(.none)
            #expect(Self.meanLuminance(unshadowed) > Self.meanLuminance(shadowed), "Unshadowed shafts must be brighter than shadowed ones.")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func lightShaftsMatchGoldenFrames() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(farMarker: true)
            try scene.configure {
                $0.fog = Fog3D(
                    isEnabled: true,
                    color: Color(red: 0.4, green: 0.45, blue: 0.5),
                    density: 0.1,
                    maximumOpacity: 0.7,
                    volumetric: VolumetricFog3D(isEnabled: true, intensity: 3, anisotropy: 0.3, steps: 32, maxDistance: 25)
                )
            }
            switch try GoldenFrame.check(try await scene.render(.none), name: "pbr-spheres-light-shafts") {
            case .recorded, .matched:
                break
            case .missingReference(let actual):
                Issue.record("No golden frame for pbr-spheres-light-shafts; record with ADAENGINE_GOLDEN_RECORD=1. Actual: \(actual.path)")
            case let .mismatched(comparison, actual, difference):
                Issue.record("pbr-spheres-light-shafts differs in \(comparison.differingPixels) pixels. Actual: \(actual.path), difference: \(difference.path)")
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func skyInfluenceControlsFogOverTheSky() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            func sky(_ image: Image) -> Float { image.getPixel(x: 10, y: 10).red - image.getPixel(x: 10, y: 10).blue }
            try scene.configure { $0.fog = Fog3D(isEnabled: true, color: Self.fogColor, density: 0.5) }
            let untouched = sky(try await scene.render(.none))
            try scene.configure { $0.fog.skyInfluence = 1 }
            let fogged = sky(try await scene.render(.none))
            #expect(fogged > untouched, "Sky influence must tint the sky (\(untouched) vs \(fogged)).")
        }
    }
}
#endif
