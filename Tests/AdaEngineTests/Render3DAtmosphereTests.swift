#if os(macOS) || os(Windows) || os(Linux)
import AdaECS
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines
@_spi(Internal) @testable import AdaRender

/// Atmosphere settings that need no GPU.
@Suite("3D atmosphere settings")
struct Render3DAtmosphereSettingsTests {
    @Test func defaultsAreOff() {
        let atmosphere = Atmosphere3D()
        #expect(!atmosphere.isEnabled && !atmosphere.changesImage)
        #expect(Environment3D().atmosphere == atmosphere)
        #expect(!atmosphere.tintsSunLight)
    }

    @Test func olderPayloadsDecodeWithoutAtmosphere() throws {
        let environment = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(environment.atmosphere == Atmosphere3D())
        let partial = try JSONDecoder().decode(Atmosphere3D.self, from: Data(#"{"isEnabled":true,"intensity":2}"#.utf8))
        #expect(partial.isEnabled && partial.intensity == 2)
        #expect(partial.mieAnisotropy == Atmosphere3D().mieAnisotropy && partial.quality == Atmosphere3D().quality)
    }

    @Test func settingsRoundTripAndFlatAccessors() throws {
        var environment = Environment3D()
        environment.atmosphereEnabled = true
        environment.atmosphereIntensity = 3
        environment.atmosphere.quality = .high
        environment.atmosphere.rayleighScale = 1.5
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.atmosphere == environment.atmosphere)
        #expect(decoded.atmosphereEnabled && decoded.atmosphereIntensity == 3)
    }

    @Test func wildValuesAreClamped() {
        let defaults = Atmosphere3D()
        let wild = Atmosphere3D(
            isEnabled: true, intensity: .nan, rayleighScale: -4, mieScale: .infinity, mieAnisotropy: 5, ozoneScale: 99,
            groundAlbedo: 3, groundRadiusMeters: -1, atmosphereHeightMeters: .nan, sunDiscScale: -1, sunDiscIntensity: .nan,
            aerialPerspectiveScale: 1000, aerialPerspectiveMaxDistance: -3
        ).sanitized
        #expect(wild.intensity == defaults.intensity)
        #expect(wild.rayleighScale == 0)
        #expect(wild.mieScale == defaults.mieScale)
        #expect(wild.mieAnisotropy == 0.99)
        #expect(wild.ozoneScale == 10)
        #expect(wild.groundAlbedo == 1)
        #expect(wild.groundRadiusMeters == 1_000)
        #expect(wild.atmosphereHeightMeters == defaults.atmosphereHeightMeters)
        #expect(wild.sunDiscScale == 0)
        #expect(wild.sunDiscIntensity == defaults.sunDiscIntensity)
        #expect(wild.aerialPerspectiveScale == 10)
        #expect(wild.aerialPerspectiveMaxDistance == 1)
    }

    @Test func sunDirectionFallbackIsUnitLength() {
        let defaults = Atmosphere3D()
        for bad in [Vector3.zero, Vector3(.nan, 1, 0), Vector3(.infinity, 0, 0)] {
            let value = Atmosphere3D(fallbackSunDirection: bad).sanitized.fallbackSunDirection
            #expect(value == defaults.fallbackSunDirection)
        }
        let scaled = Atmosphere3D(fallbackSunDirection: Vector3(0, 10, 0)).sanitized.fallbackSunDirection
        #expect(abs(scaled.length - 1) < 1e-5 && scaled.y > 0.99)
    }

    @Test func changesImageNeedsEnabledAndPositiveIntensity() {
        #expect(Atmosphere3D(isEnabled: true).changesImage)
        #expect(!Atmosphere3D(isEnabled: false).changesImage)
        #expect(!Atmosphere3D(isEnabled: true, intensity: 0).changesImage)
        #expect(!Atmosphere3D(isEnabled: true, intensity: -2).changesImage)
    }
}
#endif

#if os(macOS) || os(Windows) || os(Linux)
/// The CPU reference must be right before GPU tables are compared to it.
@Suite("3D atmosphere reference")
struct Render3DAtmosphereReferenceTests {
    typealias Reference = AtmosphereReference

    @Test func phaseFunctionsIntegrateToOne() {
        let samples = 20_000
        var rayleigh = 0.0, mie = 0.0
        for index in 0..<samples {
            let cosTheta = -1 + 2 * (Double(index) + 0.5) / Double(samples)
            rayleigh += Reference.rayleighPhase(cosTheta)
            mie += Reference.henyeyGreenstein(cosTheta, g: 0.8)
        }
        let weight = 2 * Double.pi * 2 / Double(samples)
        #expect(abs(rayleigh * weight - 1) < 1e-3)
        #expect(abs(mie * weight - 1) < 1e-3)
    }

    @Test func ozoneDensityIsATent() {
        #expect(Reference.ozoneDensity(altitude: 5_000) == 0)
        #expect(abs(Reference.ozoneDensity(altitude: 25_000) - 1) < 1e-12)
        #expect(abs(Reference.ozoneDensity(altitude: 17_500) - 0.5) < 1e-12)
        #expect(Reference.ozoneDensity(altitude: 50_000) == 0)
    }

    @Test func zenithTransmittanceMatchesOpticalDepth() throws {
        let value = try #require(Reference.transmittance(altitude: 0, cosZenith: 1))
        #expect(abs(value.r - 0.936) < 0.01)
        #expect(abs(value.g - 0.864) < 0.01)
        #expect(abs(value.b - 0.759) < 0.01)
    }

    @Test func horizonRaysLoseMoreAndReddenTheSun() throws {
        let zenith = try #require(Reference.transmittance(altitude: 0, cosZenith: 1))
        let horizon = try #require(Reference.transmittance(altitude: 0, cosZenith: 0.0))
        #expect(horizon.r < zenith.r && horizon.g < zenith.g && horizon.b < zenith.b)
        #expect(horizon.r > horizon.g && horizon.g > horizon.b)
        #expect(horizon.b < 0.01)
    }

    @Test func raysIntoTheGroundAreBlocked() {
        #expect(Reference.transmittance(altitude: 100, cosZenith: -0.5) == nil)
        #expect(Reference.transmittance(altitude: 60_000, cosZenith: -0.05) != nil)
    }

    @Test func stepCountConverges() throws {
        let coarse = try #require(Reference.transmittance(altitude: 1_000, cosZenith: 0.3, steps: 64))
        let fine = try #require(Reference.transmittance(altitude: 1_000, cosZenith: 0.3, steps: 2048))
        #expect(abs(coarse.r - fine.r) < 1e-3 && abs(coarse.b - fine.b) < 1e-3)
    }
}
#endif

#if os(macOS) || os(Windows) || os(Linux)
extension Render3DGPUTests {
    @Suite("Atmosphere tables", .enabled(if: GoldenFrame.isEnabled))
    @MainActor
    struct AtmosphereTables {
        static let width = 256
        static let height = 64
        static let medium = Atmosphere3DTier.tier(for: .medium)

        /// The transmittance table the GPU writes must match the CPU integral for every texel whose ray leaves the planet.
        @Test
        func transmittanceTableMatchesTheCPUReference() async throws {
            let scene = try await DebugViews.makeScene()
            let image = try await Self.renderTransmittance(device: scene.device)
            var compared = 0
            var worst = 0.0
            for y in stride(from: 0, to: Self.height, by: 3) {
                for x in stride(from: 0, to: Self.width, by: 5) {
                    let parameters = AtmosphereReference.transmittanceParameters(
                        uv: ((Double(x) + 0.5) / Double(Self.width), (Double(y) + 0.5) / Double(Self.height))
                    )
                    guard let expected = AtmosphereReference.transmittance(
                        altitude: parameters.radius - 6_360_000, cosZenith: parameters.cosZenith, steps: 512
                    ) else { continue }
                    let pixel = image.getPixel(x: x, y: y)
                    worst = max(worst, abs(Double(pixel.red) - expected.r), abs(Double(pixel.green) - expected.g), abs(Double(pixel.blue) - expected.b))
                    compared += 1
                }
            }
            #expect(compared > 300, "Too few texels compared: \(compared)")
            #expect(worst < 0.02, "Transmittance differs from the reference by \(worst)")
        }

        @Test
        func everyAtmospherePassBuildsAPipeline() async throws {
            let scene = try await DebugViews.makeScene()
            for name in ["transmittance", "multiscatter", "skyview", "aerial"] {
                _ = try Self.pipeline(device: scene.device, name: name)
            }
            // The production pipelines render into rgba_16f, and the aerial pass writes two attachments.
            for (name, targets) in [("transmittance", 1), ("multiscatter", 1), ("skyview", 1), ("aerial", 2)] {
                _ = try Self.pipeline(device: scene.device, name: name, format: .rgba_16f, targets: targets)
            }
        }

        @Test
        func staticTablesRebuildOnlyWhenTheKeyChanges() async throws {
            _ = try await DebugViews.makeScene()
            var store = Atmosphere3DTableStore()
            let view = Entity.ID()
            let key = Atmosphere3DUniform.staticKey(for: Atmosphere3D(isEnabled: true).sanitized)
            _ = store.tables(forView: view, tier: Self.medium)
            let first = store.claimStaticUpdate(view: view, key: key)
            let repeated = store.claimStaticUpdate(view: view, key: key)
            var changed = key
            changed.rayleighScale += 1
            let afterChange = store.claimStaticUpdate(view: view, key: changed)
            let repeatedChange = store.claimStaticUpdate(view: view, key: changed)
            #expect(first && !repeated && afterChange && !repeatedChange)
        }

        @Test
        func tablesAreReusedPerViewAndDroppedWhenUnused() async throws {
            _ = try await DebugViews.makeScene()
            var store = Atmosphere3DTableStore()
            let first: Entity.ID = 1
            let second: Entity.ID = 2
            let a = store.tables(forView: first, tier: Self.medium)
            let again = store.tables(forView: first, tier: Self.medium)
            let other = store.tables(forView: second, tier: Self.medium)
            #expect(again.skyView === a.skyView)
            #expect(other.skyView !== a.skyView)
            #expect(store.viewCount == 2)
            store.discard(view: first)
            #expect(store.tables(view: first) == nil)
            #expect(store.tables(view: second) != nil)
            #expect(store.viewCount == 1)
            store.retainViews([])
            #expect(store.viewCount == 0)
        }

        @Test
        func aDiscardedViewRebuildsItsStaticTables() async throws {
            _ = try await DebugViews.makeScene()
            var store = Atmosphere3DTableStore()
            let view = Entity.ID()
            let key = Atmosphere3DUniform.staticKey(for: Atmosphere3D(isEnabled: true).sanitized)
            _ = store.tables(forView: view, tier: Self.medium)
            let built = store.claimStaticUpdate(view: view, key: key)
            store.discard(view: view)
            _ = store.tables(forView: view, tier: Self.medium)
            let rebuilt = store.claimStaticUpdate(view: view, key: key)
            #expect(built && rebuilt)
        }

        @Test
        func perFrameTablesAreRedrawnOnlyWhenTheirInputsChange() async throws {
            _ = try await DebugViews.makeScene()
            var store = Atmosphere3DTableStore()
            let view: Entity.ID = 1
            let settings = Atmosphere3D(isEnabled: true).sanitized
            let key = Atmosphere3DUniform.staticKey(for: settings)
            _ = store.tables(forView: view, tier: Self.medium)
            func uniform(sun: Vector3 = [0, 1, 0], altitude: Float = 2, view: Transform3D = .identity) -> Atmosphere3DUniform {
                Atmosphere3DUniform(
                    atmosphere: settings, sunDirection: sun, sunRadiance: [1, 1, 1],
                    inverseView: view, inverseProjection: .identity, cameraAltitude: altitude
                )
            }
            let first = store.claimFrameUpdates(view: view, uniform: uniform(), key: key)
            let still = store.claimFrameUpdates(view: view, uniform: uniform(), key: key)
            let turnedView = Transform3D(translation: [0, 0, 0], rotation: Quat(axis: Vector3(0, 1, 0), angle: 0.3), scale: [1, 1, 1])
            let turned = store.claimFrameUpdates(view: view, uniform: uniform(view: turnedView), key: key)
            let sunMoved = store.claimFrameUpdates(view: view, uniform: uniform(sun: [0.3, 0.9, 0]), key: key)
            let climbed = store.claimFrameUpdates(view: view, uniform: uniform(sun: [0.3, 0.9, 0], altitude: 50), key: key)
            var thicker = key
            thicker.rayleighScale += 1
            let mediumChanged = store.claimFrameUpdates(view: view, uniform: uniform(sun: [0.3, 0.9, 0], altitude: 50), key: thicker)
            #expect(first.sky && first.aerial, "A new view draws everything")
            #expect(!still.sky && !still.aerial, "A still camera under a still sun redraws nothing")
            #expect(!turned.sky && turned.aerial, "Turning changes the haze but not the sky view")
            #expect(sunMoved.sky && sunMoved.aerial, "A moving sun redraws both")
            #expect(climbed.sky && climbed.aerial, "Climbing changes the sky view")
            #expect(mediumChanged.sky && mediumChanged.aerial, "A new medium redraws both")
        }

        @Test
        func tableSizesFollowTheTier() async throws {
            _ = try await DebugViews.makeScene()
            for quality in AtmosphereQuality3D.allCases {
                var store = Atmosphere3DTableStore()
                let tier = Atmosphere3DTier.tier(for: quality)
                let tables = store.tables(forView: 1, tier: tier)
                #expect(tables.transmittance.size == tier.transmittanceSize)
                #expect(tables.skyView.size == tier.skyViewSize)
                #expect(tables.aerial.size == tier.aerialSize && tables.aerialTransmittance.size == tier.aerialSize)
                #expect(tables.multiScatter.size == SizeInt(width: 32, height: 32))
            }
        }

        @Test
        func lowerTiersHoldLessMemory() async throws {
            _ = try await DebugViews.makeScene()
            var bytes: [Int] = []
            for quality in [AtmosphereQuality3D.low, .medium, .high] {
                var store = Atmosphere3DTableStore()
                _ = store.tables(forView: 1, tier: .tier(for: quality))
                bytes.append(store.memoryBytes)
            }
            #expect(bytes[0] < bytes[1] && bytes[1] < bytes[2], "Memory must grow with the tier: \(bytes)")
            #expect(bytes[0] < 150_000, "The low tier is the browser default and must stay small: \(bytes[0])")
        }

        @Test
        func changingTheTierReplacesTheTablesAndRebuildsTheStaticOnes() async throws {
            _ = try await DebugViews.makeScene()
            var store = Atmosphere3DTableStore()
            let view: Entity.ID = 1
            let low = Atmosphere3DTier.tier(for: .low)
            let key = Atmosphere3DUniform.staticKey(for: Atmosphere3D(isEnabled: true, quality: .low).sanitized)
            let first = store.tables(forView: view, tier: low)
            let built = store.claimStaticUpdate(view: view, key: key)
            let same = store.tables(forView: view, tier: low)
            let high = store.tables(forView: view, tier: .tier(for: .high))
            let rebuilt = store.claimStaticUpdate(view: view, key: Atmosphere3DUniform.staticKey(for: Atmosphere3D(isEnabled: true, quality: .high).sanitized))
            #expect(built && rebuilt)
            #expect(same.skyView === first.skyView && high.skyView !== first.skyView)
            #expect(high.skyView.size == Atmosphere3DTier.tier(for: .high).skyViewSize)
            #expect(store.viewCount == 1)
        }

        @Test
        func tableMemoryIsCountedPerViewAndReleasedWithIt() async throws {
            _ = try await DebugViews.makeScene()
            var store = Atmosphere3DTableStore()
            let perView = (256 * 64 + 32 * 32 + 192 * 108 + 2 * 512 * 32) * 8
            let empty = store.memoryBytes
            _ = store.tables(forView: 1, tier: Self.medium)
            let one = store.memoryBytes
            _ = store.tables(forView: 2, tier: Self.medium)
            let two = store.memoryBytes
            store.discard(view: 1)
            let afterDiscard = store.memoryBytes
            #expect(empty == 0 && one == perView && two == 2 * perView && afterDiscard == perView)
        }

        static func pipeline(device: RenderDevice, name: String, format: PixelFormat = .bgra8, targets: Int = 1) throws -> RenderPipeline {
            let shader = CorePipelineShaders.loadRequiredBuiltin("atmosphere_\(name)_3d")
            return device.createRenderPipeline(from: RenderPipelineDescriptor(
                vertex: try #require(shader.asset.getShader(for: .vertex)),
                fragment: shader.asset.getShader(for: .fragment), debugName: "Atmosphere \(name) test",
                backfaceCulling: false, depthPixelFormat: .none, colorAttachments: (0..<targets).map { _ in .init(format: format) }
            ))
        }

        static func earthUniform() -> Atmosphere3DUniform {
            Atmosphere3DUniform(
                inverseView: .identity, inverseProjection: .identity,
                sunDirection: [0, 1, 0, 0], sunIlluminance: [1, 1, 1, 1],
                rayleigh: [5.802e-6, 13.558e-6, 33.1e-6, 8_000], mie: [3.996e-6, 8.396e-6, 1_200, 0.8],
                ozone: [0.650e-6, 1.881e-6, 0.085e-6, 0], planet: [6_360_000, 6_460_000, 0.3, 0],
                aerial: [32_000, 1, 16, 32], steps: [40, 30, 16, 20], tables: [192, 108, 256, 64]
            )
        }

        static func renderTransmittance(device: RenderDevice) async throws -> Image {
            let pipeline = try pipeline(device: device, name: "transmittance")
            let uniform = device.createUniformBuffer(Atmosphere3DUniform.self, binding: 4)
            uniform.setData(earthUniform())
            let target = RenderTexture(size: [width, height], scaleFactor: 1, format: .bgra8)
            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .red)
            ]))
            pass.setViewport(Rect(x: 0, y: 0, width: Float(width), height: Float(height)))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBuffer(uniform, offset: 0, slot: 4)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            command.commit()
            return try #require(try await device.readImage(from: target))
        }
    }
}
#endif

#if os(macOS) || os(Windows) || os(Linux)
/// Bookkeeping and uniform packing of the atmosphere pass that need no GPU work.
@Suite("3D atmosphere resources")
struct Render3DAtmosphereResourceTests {
    private func uniform(
        _ atmosphere: Atmosphere3D = Atmosphere3D(isEnabled: true), sun: Vector3 = [0, 1, 0], altitude: Float = 2
    ) -> Atmosphere3DUniform {
        Atmosphere3DUniform(
            atmosphere: atmosphere.sanitized, sunDirection: sun, sunRadiance: [1, 0.5, 0.25],
            inverseView: .identity, inverseProjection: .identity, cameraAltitude: altitude
        )
    }

    @Test func uniformCarriesPlanetSunAndScales() {
        var atmosphere = Atmosphere3D(isEnabled: true, intensity: 2)
        atmosphere.rayleighScale = 2
        atmosphere.mieScale = 0.5
        let packed = uniform(atmosphere, sun: [0, 3, 0], altitude: 12)
        #expect(packed.sunDirection.xyz == Vector3(0, 1, 0))
        #expect(packed.sunIlluminance == Vector4(2, 1, 0.5, 2))
        #expect(abs(packed.rayleigh.x - 2 * 5.802e-6) < 1e-10 && packed.rayleigh.w == 8_000)
        #expect(abs(packed.mie.x - 0.5 * 3.996e-6) < 1e-10 && abs(packed.mie.y - 0.5 * 8.396e-6) < 1e-10)
        #expect(packed.mie.z == 1_200 && packed.mie.w == atmosphere.mieAnisotropy)
        #expect(packed.planet == Vector4(6_360_000, 6_460_000, 0.3, 12))
        #expect(packed.aerial.x == atmosphere.aerialPerspectiveMaxDistance && packed.aerial.z == 16)
    }

    @Test func metricsKeepTheLatestMemoryFigurePerResource() {
        let metrics = Render3DPerformanceMetrics()
        metrics.record(memory: "atmosphere", bytes: 100)
        metrics.record(memory: "atmosphere", bytes: 436_224)
        metrics.record(memory: "fog", bytes: 2_048)
        #expect(metrics.memoryBytes == ["atmosphere": 436_224, "fog": 2_048])
        let report = metrics.report()
        #expect(report.contains("atmosphere") && report.contains("426.0 KiB") && report.contains("fog") && report.contains("2.0 KiB"))
    }

    @Test func aMemoryFigureOfZeroRemovesTheEntry() {
        let metrics = Render3DPerformanceMetrics()
        metrics.record(memory: "atmosphere", bytes: 4_096)
        metrics.record(memory: "atmosphere", bytes: 0)
        #expect(metrics.memoryBytes.isEmpty)
    }

    @Test func sunTransmittanceMatchesTheCPUReference() {
        let settings = Atmosphere3D(isEnabled: true).sanitized
        for (altitude, direction) in [(Float(0), Vector3(0, 1, 0)), (Float(0), Vector3(1, 0.2, 0)), (Float(2_000), Vector3(0, 0.05, 1))] {
            let cosZenith = Double(direction.normalized.y)
            let expected = AtmosphereReference.transmittance(altitude: Double(altitude), cosZenith: cosZenith, steps: 1024)
            let value = Atmosphere3DMath.sunTransmittance(atmosphere: settings, altitude: altitude, sunDirection: direction)
            #expect(abs(Double(value.x) - (expected?.r ?? -1)) < 0.01 && abs(Double(value.y) - (expected?.g ?? -1)) < 0.01
                && abs(Double(value.z) - (expected?.b ?? -1)) < 0.01, "altitude \(altitude), sun \(direction): \(value) against \(String(describing: expected))")
        }
    }

    @Test func theSunReddensAsItSinksAndGoesOutBelowTheHorizon() {
        let settings = Atmosphere3D(isEnabled: true).sanitized
        let noon = Atmosphere3DMath.sunTransmittance(atmosphere: settings, altitude: 0, sunDirection: [0, 1, 0])
        let low = Atmosphere3DMath.sunTransmittance(atmosphere: settings, altitude: 0, sunDirection: [1, 0.05, 0])
        let night = Atmosphere3DMath.sunTransmittance(atmosphere: settings, altitude: 0, sunDirection: [1, -0.3, 0])
        #expect(low.x < noon.x && low.z < noon.z)
        #expect(low.x / low.z > noon.x / noon.z * 2, "Low sun must be markedly redder: \(low) against \(noon)")
        #expect(night == .zero)
    }

    @Test func aThickerAtmosphereDimsTheSunMore() {
        var thick = Atmosphere3D(isEnabled: true)
        thick.rayleighScale = 3
        let base = Atmosphere3DMath.sunTransmittance(atmosphere: Atmosphere3D(isEnabled: true).sanitized, altitude: 0, sunDirection: [0, 1, 0])
        let dim = Atmosphere3DMath.sunTransmittance(atmosphere: thick.sanitized, altitude: 0, sunDirection: [0, 1, 0])
        #expect(dim.x < base.x && dim.y < base.y && dim.z < base.z)
    }

    @Test func negativeAltitudeIsClampedToTheGround() {
        #expect(uniform(altitude: -50).planet.w == 0)
    }

    @Test func tiersGrowWithQuality() {
        let low = Atmosphere3DTier.tier(for: .low)
        let medium = Atmosphere3DTier.tier(for: .medium)
        let high = Atmosphere3DTier.tier(for: .high)
        #expect(low.skyViewSteps > 0 && low.aerialSteps > 0 && low.transmittanceSteps > 0 && low.multiScatterSteps > 0)
        #expect(low.skyViewSteps < medium.skyViewSteps && medium.skyViewSteps < high.skyViewSteps)
        #expect(low.aerialSteps < medium.aerialSteps && medium.aerialSteps < high.aerialSteps)
        #expect(high.skyViewSteps <= 64 && high.transmittanceSteps <= 128 && high.multiScatterSteps <= 32)
        #expect(uniform(Atmosphere3D(isEnabled: true, quality: .high)).steps.y == Float(high.skyViewSteps))
    }

    @Test func tableSizesAndSlicesGrowWithQuality() {
        let low = Atmosphere3DTier.tier(for: .low)
        let medium = Atmosphere3DTier.tier(for: .medium)
        let high = Atmosphere3DTier.tier(for: .high)
        #expect(low.skyViewSize.width < medium.skyViewSize.width && medium.skyViewSize.width < high.skyViewSize.width)
        #expect(low.transmittanceSize.width < medium.transmittanceSize.width)
        #expect(low.aerialSlices < medium.aerialSlices && medium.aerialSlices < high.aerialSlices)
        #expect(low.aerialTile < medium.aerialTile && medium.aerialSize == SizeInt(width: 512, height: 32))
        let packed = uniform(Atmosphere3D(isEnabled: true, quality: .high))
        #expect(packed.tables == Vector4(256, 144, 256, 64))
        #expect(packed.aerial.z == 24 && packed.aerial.w == 32)
        #expect(uniform(Atmosphere3D(isEnabled: true, quality: .low)).aerial.z == 8)
    }

    @Test func staticKeyIgnoresSunAndCameraButNotTheMedium() {
        let base = Atmosphere3D(isEnabled: true).sanitized
        let key = Atmosphere3DUniform.staticKey(for: base)
        var moved = base
        moved.fallbackSunDirection = [1, 0, 0]
        moved.intensity = 5
        moved.sunDiscScale = 3
        #expect(Atmosphere3DUniform.staticKey(for: moved) == key)
        var thicker = base
        thicker.rayleighScale = 2
        #expect(Atmosphere3DUniform.staticKey(for: thicker) != key)
        var faster = base
        faster.quality = base.quality == .high ? .low : .high
        #expect(Atmosphere3DUniform.staticKey(for: faster) != key)
        var albedo = base
        albedo.groundAlbedo = 0.9
        #expect(Atmosphere3DUniform.staticKey(for: albedo) != key)
    }

}
#endif

#if os(macOS) || os(Windows) || os(Linux)
extension Render3DGPUTests {
    /// The physical sky seen through the real composite pass.
    @Suite("Atmosphere composite", .enabled(if: GoldenFrame.isEnabled))
    @MainActor
    struct AtmosphereComposite {
        /// Rotation about X in radians. The light shines along its local +Z, so +pi/2 puts the sun overhead and 0 puts it behind the camera at the horizon.
        enum Sun {
            static let noon: Float = 1.5
            static let lowSun: Float = .pi - 0.17
            static let night: Float = -0.5
        }

        private static func luminance(_ color: Color) -> Float {
            0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        }

        private static func scene(sun pitch: Float, atmosphere: Bool = true, facingAway: Bool = false, farMarker: Bool = false) async throws
            -> DebugViews.Scene
        {
            let scene = try await DebugViews.makeScene(farMarker: farMarker)
            scene.sun.components[Transform.self] = Transform(rotation: Quat(axis: Vector3(1, 0, 0), angle: pitch))
            try scene.configure { environment in
                environment.atmosphere = Atmosphere3D(isEnabled: atmosphere)
            }
            if facingAway {
                scene.camera.components[Transform.self] = Transform(rotation: Quat(axis: Vector3(0, 1, 0), angle: .pi), position: [0, 0.5, -3.4])
            }
            return scene
        }

        @Test
        func theSkyIsBlueBySunlightAndDarkAtNight() async throws {
            var levels: [Float] = []
            var noon: Color?
            for pitch in [Sun.noon, Sun.lowSun, Sun.night] {
                let scene = try await Self.scene(sun: pitch)
                let image = try await scene.render(.none)
                let sky = image.getPixel(x: DebugViews.width / 2, y: 8)
                levels.append(Self.luminance(sky))
                if pitch == Sun.noon { noon = sky }
            }
            let sky = try #require(noon)
            #expect(sky.blue > sky.red, "A clear daytime sky is bluer than it is red")
            #expect(levels[0] > levels[1] && levels[1] > levels[2], "Sky brightness must fall from noon to low sun to night: \(levels)")
            #expect(levels[2] < 0.05, "The night sky must be dark: \(levels[2])")
            #expect(levels[0] > 0.08, "The noon sky must be visibly lit: \(levels[0])")
        }

        @Test
        func theSkyAndThePlanetAreSmoothOnEachSideOfTheHorizon() async throws {
            let scene = try await Self.scene(sun: Sun.noon, facingAway: true)
            let image = try await scene.render(.none)
            // The camera is level, so the horizon is the middle row. The planet surface really is darker than the haze above
            // it, so each side is checked on its own. Rows from 70% down see the cube's far edge.
            let horizon = DebugViews.height / 2
            let ranges = [1..<(horizon - 4), (horizon + 5)..<Int(Float(DebugViews.height) * 0.7)]
            var largestStep: Float = 0
            for x in stride(from: 8, to: DebugViews.width, by: 64) {
                for range in ranges {
                    for y in range {
                        let step = abs(Self.luminance(image.getPixel(x: x, y: y)) - Self.luminance(image.getPixel(x: x, y: y - 1)))
                        largestStep = max(largestStep, step)
                    }
                }
            }
            #expect(largestStep < 0.03, "Adjacent rows differ by \(largestStep) away from the horizon")
        }

        @Test
        func aDisabledAtmosphereLeavesTheImageUnchanged() async throws {
            let plain = try await DebugViews.makeScene()
            let baseline = try await plain.render(.none)
            let scene = try await DebugViews.makeScene()
            try scene.configure { environment in
                environment.atmosphere = Atmosphere3D(isEnabled: false, intensity: 9, rayleighScale: 3, aerialPerspectiveScale: 10)
            }
            let image = try await scene.render(.none)
            var differing = 0
            for y in 0..<DebugViews.height {
                for x in 0..<DebugViews.width where image.getPixel(x: x, y: y) != baseline.getPixel(x: x, y: y) { differing += 1 }
            }
            #expect(differing == 0, "\(differing) pixels changed with the atmosphere off")
        }

        @Test
        func aerialPerspectiveBrightensGeometryButNotTheSky() async throws {
            let clear = try await Self.scene(sun: Sun.noon, farMarker: true)
            try clear.configure { $0.atmosphere.aerialPerspectiveScale = 0 }
            let hazy = try await Self.scene(sun: Sun.noon, farMarker: true)
            try hazy.configure { $0.atmosphere.aerialPerspectiveScale = 10 }
            let without = try await clear.render(.none)
            let with = try await hazy.render(.none)
            var brighter = 0
            var darker = 0
            for y in 0..<DebugViews.height {
                for x in 0..<DebugViews.width {
                    let delta = Self.luminance(with.getPixel(x: x, y: y)) - Self.luminance(without.getPixel(x: x, y: y))
                    if delta > 0.004 { brighter += 1 } else if delta < -0.004 { darker += 1 }
                }
            }
            #expect(brighter > 500, "Haze must add light over distant geometry: \(brighter) pixels")
            #expect(darker < brighter / 10, "Haze must not darken the frame: \(darker) pixels")
            let sky = (x: DebugViews.width / 2, y: 4)
            #expect(with.getPixel(x: sky.x, y: sky.y) == without.getPixel(x: sky.x, y: sky.y), "Sky pixels carry no aerial haze")
        }

        /// Largest row-to-row luminance step down the middle of the last sphere, relative to its mean luminance.
        private static func reflectionSharpness(roughness: Float) async throws -> Float {
            let scene = try await Self.scene(sun: Sun.noon)
            // No direct light, so the sphere shows only the sky reflected in it.
            try scene.setSunIntensity(0)
            let entity = scene.sphereEntities[3]
            var component = try #require(entity.components[Mesh3DComponent.self])
            let material = PBRMaterial()
            material.baseColorFactor = [0.9, 0.9, 0.9, 1]
            material.metallicFactor = 1
            material.roughnessFactor = roughness
            component.materials = [material]
            entity.components[Mesh3DComponent.self] = component
            let image = try await scene.render(.none)
            let column = 490
            var total: Float = 0
            var largest: Float = 0
            let rows = 196..<286
            for y in rows {
                total += Self.luminance(image.getPixel(x: column, y: y))
                largest = max(largest, abs(Self.luminance(image.getPixel(x: column, y: y + 1)) - Self.luminance(image.getPixel(x: column, y: y))))
            }
            return largest / max(total / Float(rows.count), 0.0001)
        }

        @Test
        func roughSurfacesReflectABlurredSky() async throws {
            let mirror = try await Self.reflectionSharpness(roughness: 0.05)
            let rough = try await Self.reflectionSharpness(roughness: 0.9)
            #expect(mirror > 0.05, "A smooth metal sphere should show the horizon in its reflection: \(mirror)")
            #expect(rough < mirror * 0.55, "A rough sphere must reflect a blurred sky: rough \(rough), mirror \(mirror)")
        }

        @Test
        func theSameSettingsRenderTheSameFrame() async throws {
            let first = try await Self.scene(sun: Sun.lowSun)
            let second = try await Self.scene(sun: Sun.lowSun)
            let a = try await first.render(.none)
            let b = try await second.render(.none)
            var differing = 0
            for y in 0..<DebugViews.height {
                for x in 0..<DebugViews.width where a.getPixel(x: x, y: y) != b.getPixel(x: x, y: y) { differing += 1 }
            }
            #expect(differing == 0, "\(differing) pixels differ between two renders with identical settings")
        }

        @Test
        func aZeroSizedSunDiscDrawsNoDisc() async throws {
            // At low sun the disc sits near the middle of the frame, above the spheres.
            let withDisc = try await Self.scene(sun: Sun.lowSun)
            let without = try await Self.scene(sun: Sun.lowSun)
            try without.configure { $0.atmosphere.sunDiscScale = 0 }
            let lit = try await withDisc.render(.none)
            let dark = try await without.render(.none)
            var brightest: Float = 0
            var brightestWithout: Float = 0
            for y in 150..<210 {
                for x in 290..<350 {
                    brightest = max(brightest, Self.luminance(lit.getPixel(x: x, y: y)))
                    brightestWithout = max(brightestWithout, Self.luminance(dark.getPixel(x: x, y: y)))
                }
            }
            #expect(brightest > 0.95, "The default sun disc must be visible: \(brightest)")
            #expect(brightestWithout.isFinite && brightestWithout < brightest - 0.1, "A zero-sized disc must leave no bright pixel: \(brightestWithout) against \(brightest)")
        }

        @Test
        func hazeOverDistantGeometryTakesTheColorOfTheSky() async throws {
            // The far marker is a dark sphere about 7.4 m away. Meters of air scatter little, so the haze is boosted, and
            // what it adds must be tinted like the noon sky behind it: more blue than red.
            let clear = try await Self.scene(sun: Sun.noon, farMarker: true)
            try clear.configure { $0.atmosphere.aerialPerspectiveScale = 0 }
            let hazy = try await Self.scene(sun: Sun.noon, farMarker: true)
            try hazy.configure {
                $0.atmosphere.aerialPerspectiveMaxDistance = 12
                $0.atmosphere.aerialPerspectiveScale = 10
                $0.atmosphere.mieScale = 0
                $0.atmosphere.rayleighScale = 10
            }
            let without = try await clear.render(.none)
            let with = try await hazy.render(.none)
            let marker = (x: 376, y: 144)
            let sky = without.getPixel(x: marker.x, y: 60)
            let probe = without.getPixel(x: marker.x, y: marker.y)
            #expect(Self.luminance(probe) < 0.5 * Self.luminance(sky), "The probe must land on the dark marker")
            var added = (red: Float(0), green: Float(0), blue: Float(0))
            for y in (marker.y - 3)...(marker.y + 3) {
                for x in (marker.x - 3)...(marker.x + 3) {
                    let a = without.getPixel(x: x, y: y)
                    let b = with.getPixel(x: x, y: y)
                    added.red += (b.red - a.red) / 49
                    added.green += (b.green - a.green) / 49
                    added.blue += (b.blue - a.blue) / 49
                }
            }
            #expect(added.blue > 0.003, "Haze must add light to the far marker: \(added)")
            #expect(added.blue > added.red, "The added haze must be bluer than red, like the sky: \(added)")
        }

        @Test
        func tintingTheSunLightReddensAndDimsALowSun() async throws {
            let plain = try await Self.scene(sun: Sun.lowSun)
            let tinted = try await Self.scene(sun: Sun.lowSun)
            try tinted.configure { $0.atmosphere.tintsSunLight = true }
            let before = try await plain.render(.none)
            let after = try await tinted.render(.none)
            // The lit strip of ground below the spheres, in the middle of the frame.
            func average(_ image: Image) -> (red: Float, blue: Float) {
                var red: Float = 0
                var blue: Float = 0
                for y in 400..<440 {
                    for x in 300..<340 {
                        let pixel = image.getPixel(x: x, y: y)
                        red += pixel.red / 1600
                        blue += pixel.blue / 1600
                    }
                }
                return (red, blue)
            }
            let a = average(before)
            let b = average(after)
            #expect(a.red > 0.05, "The probe must land on lit ground: \(a)")
            #expect(b.red < a.red && b.blue < a.blue, "The tinted sun must be dimmer: \(a) then \(b)")
            #expect(b.red / b.blue > a.red / a.blue * 1.1, "The tinted sun must be redder: \(a) then \(b)")
        }

        @Test
        func skyFramesMatchTheirGoldenReferences() async throws {
            for (name, pitch) in [("atmosphere-noon", Sun.noon), ("atmosphere-low-sun", Sun.lowSun), ("atmosphere-night", Sun.night)] {
                let scene = try await Self.scene(sun: pitch)
                let image = try await scene.render(.none)
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
#endif
