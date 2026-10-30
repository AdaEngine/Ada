#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) import AdaApp
import AdaECS
@_spi(Internal) import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

/// Automatic exposure settings that need no GPU.
@Suite("3D auto exposure settings")
struct Render3DAutoExposureSettingsTests {
    @Test func defaultsAreOffWithAThreeStopRange() {
        let settings = AutoExposure3D()
        #expect(!settings.isEnabled)
        #expect(settings.minimumEV == -3 && settings.maximumEV == 3)
        #expect(PostProcess3D().autoExposure == settings)
    }

    @Test func olderPayloadsDecodeWithoutAutoExposure() throws {
        let decoded = try JSONDecoder().decode(PostProcess3D.self, from: Data(#"{"exposureEV":0.5}"#.utf8))
        #expect(decoded.autoExposure == AutoExposure3D())
        let partial = try JSONDecoder().decode(AutoExposure3D.self, from: Data(#"{"isEnabled":true,"maximumEV":5}"#.utf8))
        #expect(partial.isEnabled && partial.maximumEV == 5 && partial.minimumEV == -3)
    }

    @Test func settingsRoundTripAndFlatAccessor() throws {
        var environment = Environment3D()
        environment.autoExposureEnabled = true
        environment.postProcess.autoExposure = AutoExposure3D(isEnabled: true, minimumEV: -2, maximumEV: 4, speedUp: 0.5, speedDown: 3)
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.postProcess.autoExposure == environment.postProcess.autoExposure)
        #expect(decoded.autoExposureEnabled)
    }

    @Test func limitsAreOrderedClampedAndSpeedsFinite() {
        let swapped = AutoExposure3D(minimumEV: 4, maximumEV: -4).sanitized
        #expect(swapped.minimumEV == -4 && swapped.maximumEV == 4)
        let wild = AutoExposure3D(minimumEV: -100, maximumEV: .nan, speedUp: .nan, speedDown: -5).sanitized
        #expect(wild.minimumEV == -10)
        #expect(wild.maximumEV == AutoExposure3D().maximumEV)
        #expect(wild.speedUp == AutoExposure3D().speedUp)
        #expect(wild.speedDown == 0)
        #expect(AutoExposure3D(speedUp: .infinity, speedDown: .infinity).sanitized.speedUp == AutoExposure3D.snapSpeed)
        #expect(AutoExposure3D(speedUp: 5000).sanitized.speedUp == 1000)
    }
}

extension Render3DGPUTests {
    /// Renders automatic exposure through the real Metal pipeline.
    ///
    /// Run alone: `ADAENGINE_GOLDEN_METAL=1 swift test --filter Render3DAutoExposureGPUTests`.
    @Suite("3D auto exposure on GPU")
    @MainActor
    struct AutoExposure {
        /// Snaps to the metered exposure on every frame, so results do not depend on frame timing.
        private static let snapping = AutoExposure3D(isEnabled: true, minimumEV: -6, maximumEV: 6, speedUp: .infinity, speedDown: .infinity)
        private static let probes = [(320, 440), (100, 450), (150, 230), (200, 215)]

        private static func luminance(_ color: Color) -> Float { (color.red + color.green + color.blue) / 3 }

        private static func groundBrightness(_ image: Image) -> Float { luminance(image.getPixel(x: 320, y: 440)) }

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

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled), arguments: Render3DPostProcessGPUTests.Path.supported)
        func aPinnedRangeMatchesManualExposureOnEveryPath(path: Render3DPostProcessGPUTests.Path) async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene(
                antiAliasing: path == .fxaa ? .fxaa : .none,
                temporalRenderScale: path == .temporal ? 1 : nil
            )
            // Temporal jitter repeats every eight frames, so renders of equal length land on the same phase.
            let frames = path == .temporal ? 16 : 6
            try scene.configure { $0.postProcess.exposureEV = 1 }
            let manual = try await scene.render(.none, frames: frames)
            try scene.configure {
                $0.postProcess.exposureEV = 0
                $0.postProcess.autoExposure = AutoExposure3D(isEnabled: true, minimumEV: 1, maximumEV: 1, speedUp: .infinity, speedDown: .infinity)
            }
            let automatic = try await scene.render(.none, frames: frames)
            for (x, y) in Self.probes {
                let left = automatic.getPixel(x: x, y: y), right = manual.getPixel(x: x, y: y)
                let difference = max(abs(left.red - right.red), abs(left.green - right.green), abs(left.blue - right.blue)) * 255
                #expect(difference <= (path == .temporal ? 6 : 3), "\(path): a +1 EV auto range differs from +1 EV manual by \(difference) steps at (\(x), \(y)).")
            }
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func autoExposureEvensOutSceneBrightness() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.setSunIntensity(3)
            let brightManual = Self.groundBrightness(try await scene.render(.none))
            try scene.setSunIntensity(0.4)
            let dimManual = Self.groundBrightness(try await scene.render(.none))
            let manualSpread = abs(brightManual - dimManual)
            #expect(manualSpread > 0.1, "The two lighting levels must differ visibly without auto exposure (\(manualSpread)).")

            try scene.configure { $0.postProcess.autoExposure = Self.snapping }
            try scene.setSunIntensity(3)
            let brightAuto = Self.groundBrightness(try await scene.render(.none, frames: 6))
            try scene.setSunIntensity(0.4)
            let dimAuto = Self.groundBrightness(try await scene.render(.none, frames: 6))
            let autoSpread = abs(brightAuto - dimAuto)
            #expect(autoSpread < manualSpread * 0.5, "Auto exposure must narrow the brightness gap: \(autoSpread) against \(manualSpread) without it.")
            // Both scenes average below mid gray, so both are brightened, the dimmer one by more.
            #expect(dimAuto > dimManual + 0.05, "A dim scene must be brightened.")
            #expect(dimAuto - dimManual > brightAuto - brightManual, "The dim scene must gain more than the bright one.")
            try scene.setSunIntensity(0.4)
            try Self.expectGolden(try await scene.render(.none, frames: 6), named: "pbr-spheres-dim-autoexposure")
            try scene.configure { $0.postProcess.autoExposure.isEnabled = false }
            try Self.expectGolden(try await scene.render(.none, frames: 6), named: "pbr-spheres-dim-manual")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func adaptationSpeedControlsHowFastExposureFollowsTheScene() async throws {
            let slowScene = try await Render3DDebugViewGPUTests.makeScene()
            try slowScene.setSunIntensity(3)
            try slowScene.configure { $0.postProcess.autoExposure = AutoExposure3D(isEnabled: true, minimumEV: -6, maximumEV: 6, speedUp: 0.001, speedDown: 0.001) }
            let before = Self.groundBrightness(try await slowScene.render(.none, frames: 6))
            try slowScene.setSunIntensity(0.4)
            let slow = Self.groundBrightness(try await slowScene.render(.none, frames: 6))

            let snapScene = try await Render3DDebugViewGPUTests.makeScene()
            try snapScene.setSunIntensity(3)
            try snapScene.configure { $0.postProcess.autoExposure = Self.snapping }
            _ = try await snapScene.render(.none, frames: 6)
            try snapScene.setSunIntensity(0.4)
            let snapped = Self.groundBrightness(try await snapScene.render(.none, frames: 6))

            #expect(slow < before, "The dimmer scene reads darker while exposure has barely moved.")
            #expect(snapped > slow + 0.08, "Snapping must have re-exposed the dim scene (\(snapped)) well beyond the sluggish one (\(slow)).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func disabledAutoExposureChangesNothingAndHoldsNoState() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            func views() throws -> AutoExposure3DViews { try #require(renderWorld.getResource(AutoExposure3DViews.self)) }
            let baseline = try await scene.render(.none)
            try scene.configure { $0.postProcess.autoExposure = AutoExposure3D(isEnabled: false, minimumEV: 5, maximumEV: 5) }
            let off = try await scene.render(.none)
            #expect(GoldenFrame.compare(baseline, off, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            #expect(try views().output(view: scene.camera.id) == nil)

            try scene.configure { $0.postProcess.autoExposure = Self.snapping }
            _ = try await scene.render(.none)
            #expect(try views().output(view: scene.camera.id)?.size == SizeInt(width: 1, height: 1))
            try scene.configure { $0.postProcess.autoExposure.isEnabled = false }
            let released = try await scene.render(.none)
            #expect(try views().output(view: scene.camera.id) == nil, "Turning it off must release the state.")
            #expect(GoldenFrame.compare(baseline, released, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func aFrameWithoutGeometryHoldsTheLastExposure() async throws {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            try scene.setSunIntensity(0.4)
            let skyOff = Self.luminance(try await scene.render(.none).getPixel(x: 320, y: 40))
            try scene.configure { $0.postProcess.autoExposure = Self.snapping }
            let skyMetered = Self.luminance(try await scene.render(.none, frames: 6).getPixel(x: 320, y: 40))
            #expect(abs(skyMetered - skyOff) > 0.04, "The dim scene must have changed exposure, so the sky reads differently (\(skyMetered) vs \(skyOff)).")
            // Look straight up: nothing but sky is covered, so the meter has nothing to average.
            var transform = try #require(scene.camera.components[Transform.self])
            transform.rotation = Quat(axis: .right, angle: -1.2)
            scene.camera.components[Transform.self] = transform
            let skyOnly = try await scene.render(.none, frames: 6)
            #expect(abs(Self.luminance(skyOnly.getPixel(x: 320, y: 240)) - skyMetered) <= 0.02, "Exposure must hold when no geometry is visible.")
        }

        /// A neutral emissive wall gives the real meter a known luminance, independent of sunlight/shadows.
        private static func makeMeterScene() async throws -> (Render3DDebugViewGPUTests.Scene, PBRMaterial) {
            let scene = try await Render3DDebugViewGPUTests.makeScene()
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            try scene.setSunIntensity(0)
            scene.camera.components[Transform.self] = Transform(position: [0, 0, -2])
            try scene.configure {
                $0.imageBasedLighting = nil
                $0.screenSpaceReflection.isEnabled = false
                $0.ambientOcclusion.isEnabled = false
                $0.skybox.isEnabled = false
                $0.postProcess.bloom.isEnabled = false
            }
            let material = PBRMaterial()
            material.baseColorFactor = [0, 0, 0, 1]
            material.metallicFactor = 0
            material.emissiveFactor = .one
            material.emissiveStrength = 0.002
            scene.app.main.spawn("Exposure meter wall") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [8, 8, 0.1], renderDevice: scene.device), materials: [material],
                                castShadows: false, receiveShadows: false)
                Transform()
            }
            return (scene, material)
        }

        /// Drive the production GPU adaptation with a deterministic clock; only the final frame is read back.
        private static func advance(_ scene: Render3DDebugViewGPUTests.Scene, time: inout Double, step: Double, frames: Int = 1) async throws -> Image {
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let state = world.getRefResource(AutoExposure3DViews.self)
            for _ in 0..<frames {
                time += step
                let stamp = time
                state.wrappedValue.clock = { stamp }
                try await scene.app.update()
            }
            return try await scene.render(.none, frames: 0)
        }

        /// Test-only GPU readback of the two half channels. Runtime exposure stays entirely on the GPU.
        private static func currentEV(_ scene: Render3DDebugViewGPUTests.Scene) async throws -> Float {
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let texture = try #require(world.getResource(AutoExposure3DViews.self)?.output(view: scene.camera.id))
            let state = try await Self.halfPixel(scene, texture: texture)
            return state.x + state.y
        }

        private static func halfPixel(_ scene: Render3DDebugViewGPUTests.Scene, texture: Texture, x: Int = 0, y: Int = 0) async throws -> Vector4 {
            let buffer = scene.device.createBuffer(label: "Exposure test readback", length: 256, options: .storageShared)
            let command = scene.device.createCommandQueue().makeCommandBuffer()
            let blit = command.beginBlitPass(.init())
            blit.copyTextureToBuffer(source: texture, sourceOrigin: .init(x: x, y: y), sourceMipLevel: 0, sourceSlice: 0,
                                     sourceSize: .init(width: 1, height: 1), destination: buffer, destinationOffset: 0,
                                     destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            blit.endBlitPass()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { continuation.resume() }
                command.commit()
            }
            let data = try await buffer.readData()
            return data.withUnsafeBytes { bytes in
                func channel(_ index: Int) -> Float {
                    Float(Float16(bitPattern: unsafe bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)))
                }
                return Vector4(channel(0), channel(1), channel(2), channel(3))
            }
        }

        /// Newly spawned meshes need extraction before the first valid render. Check HDR itself so a sky-only
        /// startup frame can never be mistaken for the metered wall or pass a display-brightness assertion.
        private static func requireMeterWall(_ scene: Render3DDebugViewGPUTests.Scene, luminance expected: Float) async throws {
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            let camera = try #require(world.getEntities().first { $0.components[ExtractedCameraSource.self]?.entityId == scene.camera.id })
            let texture = try #require(camera.components[RenderViewTarget.self]?.sceneColor3DTexture)
            let pixel = try await Self.halfPixel(scene, texture: texture, x: 320, y: 240)
            let relativeError = abs((pixel.x + pixel.y + pixel.z) / 3 - expected) / expected
            try #require(pixel.w > 0.99 && relativeError < 0.01,
                         "The extracted HDR wall must be visible at the requested luminance before measuring adaptation: \(pixel), expected \(expected).")
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func leavingDarknessOverexposesThenSettlesAndTheReturnIsSlower() async throws {
            let (scene, wall) = try await Self.makeMeterScene()
            var time: Double = 10
            try scene.configure { $0.postProcess.autoExposure = Self.snapping }
            let darkSettled = try await Self.advance(scene, time: &time, step: 1 / 60, frames: 6)
            try await Self.requireMeterWall(scene, luminance: 0.002)
            let darkEV = try await Self.currentEV(scene)
            try scene.configure { $0.postProcess.autoExposure.speedUp = 0.5; $0.postProcess.autoExposure.speedDown = 2.5 }
            wall.emissiveStrength = 2
            let sunTransient = try await Self.advance(scene, time: &time, step: 1 / 60)
            _ = try await Self.advance(scene, time: &time, step: 0.25, frames: 4)
            let sunAfterOneSecond = try await Self.currentEV(scene)
            let sunSettled = try await Self.advance(scene, time: &time, step: 0.25, frames: 20)
            let sunEV = try await Self.currentEV(scene)
            wall.emissiveStrength = 0.002
            let darkTransient = try await Self.advance(scene, time: &time, step: 1 / 60)
            _ = try await Self.advance(scene, time: &time, step: 0.25, frames: 4)
            let darkAfterOneSecond = try await Self.currentEV(scene)
            let range = darkEV - sunEV
            let sunProgress = (darkEV - sunAfterOneSecond) / range
            let darkProgress = (darkAfterOneSecond - sunEV) / range
            let transient = Self.luminance(sunTransient.getPixel(x: 320, y: 240))
            let settled = Self.luminance(sunSettled.getPixel(x: 320, y: 240))
            #expect(range > 6, "The fixture must cross a large physical luminance range: \(range) stops.")
            #expect(transient > settled + 0.2, "Leaving darkness must visibly overexpose before settling: \(transient) vs \(settled).")
            #expect(Self.luminance(darkTransient.getPixel(x: 320, y: 240)) < Self.luminance(darkSettled.getPixel(x: 320, y: 240)) * 0.2)
            #expect(sunProgress > 0.85 && darkProgress < 0.5 && sunProgress > darkProgress * 2,
                    "At equal elapsed time, bright adaptation must be faster: \(sunProgress) vs \(darkProgress).")

            try scene.configure { $0.postProcess.autoExposure.speedUp = 0; $0.postProcess.autoExposure.speedDown = 0 }
            _ = try await Self.advance(scene, time: &time, step: 0.25, frames: 4)
            #expect(abs(try await Self.currentEV(scene) - darkAfterOneSecond) < 0.00001, "Zero speeds freeze history for pause.")
            try scene.configure { $0.postProcess.autoExposure.maximumEV = -1 }
            _ = try await Self.advance(scene, time: &time, step: 0.25)
            #expect(try await Self.currentEV(scene) <= -1 + 0.00001, "A tighter profile limit applies even while adaptation is held.")

            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            for (name, image) in [("dark-settled", darkSettled), ("sun-transient", sunTransient), ("sun-settled", sunSettled), ("dark-transient", darkTransient)] {
                try image.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("eye-adaptation-\(name).png"))
            }
            let measurements = ["darkEV": darkEV, "sunEV": sunEV, "sunTransientLuminance": transient, "sunSettledLuminance": settled,
                                "sunProgressAfterOneSecond": sunProgress, "darkProgressAfterOneSecond": darkProgress]
            try JSONEncoder().encode(measurements).write(to: GoldenFrame.outputDirectory.appendingPathComponent("eye-adaptation.json"))
        }

        @Test(.enabled(if: Render3DDebugViewGPUTests.enabled))
        func dimSurfacesAreMeteredAndSlowAdaptationDoesNotStallAt140FPS() async throws {
            let (scene, wall) = try await Self.makeMeterScene()
            var time: Double = 10
            wall.emissiveStrength = 0.00005
            try scene.configure { $0.postProcess.autoExposure = AutoExposure3D(isEnabled: true, minimumEV: -10, maximumEV: 10,
                                                                            speedUp: .infinity, speedDown: .infinity) }
            let dim = try await Self.advance(scene, time: &time, step: 1 / 140, frames: 6)
            try await Self.requireMeterWall(scene, luminance: 0.00005)
            #expect(try await Self.currentEV(scene) > 8, "Positive luminance below 0.001 must still contribute to metering.")
            #expect(Self.luminance(dim.getPixel(x: 320, y: 240)) > 0.1)
            wall.emissiveStrength = 0.18 / 64
            try scene.configure { $0.postProcess.autoExposure = AutoExposure3D(isEnabled: true, minimumEV: 5.8, maximumEV: 5.8,
                                                                            speedUp: .infinity, speedDown: .infinity) }
            _ = try await Self.advance(scene, time: &time, step: 1 / 140)
            let initial = try await Self.currentEV(scene)
            try scene.configure { $0.postProcess.autoExposure = AutoExposure3D(isEnabled: true, minimumEV: -6, maximumEV: 6, speedUp: 0.1, speedDown: 0.1) }
            _ = try await Self.advance(scene, time: &time, step: 1 / 140, frames: 140)
            let adapted = try await Self.currentEV(scene)
            #expect(adapted > initial + 0.01 && adapted < 6,
                    "Small real temporal increments must accumulate instead of rounding back to the same half EV: \(initial) -> \(adapted).")
        }
    }
}

typealias Render3DAutoExposureGPUTests = Render3DGPUTests.AutoExposure

#endif
