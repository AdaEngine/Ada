#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaECS
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines
@_spi(Internal) @testable import AdaRender

/// Cloud settings that need no GPU.
@Suite("3D cloud settings")
struct Render3DCloudSettingsTests {
    @Test func defaultsAreOff() {
        let clouds = VolumetricClouds3D()
        #expect(!clouds.isEnabled && !clouds.changesImage)
        #expect(Atmosphere3D().clouds == clouds)
        #expect(clouds.time == nil)
    }

    @Test func atmosphereSettingsWithoutCloudsDecodeUnchanged() throws {
        let atmosphere = try JSONDecoder().decode(Atmosphere3D.self, from: Data(#"{"isEnabled":true,"intensity":2}"#.utf8))
        #expect(atmosphere.clouds == VolumetricClouds3D())
        let environment = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(environment.atmosphere.clouds == VolumetricClouds3D())
        let partial = try JSONDecoder().decode(VolumetricClouds3D.self, from: Data(#"{"isEnabled":true,"coverage":0.8,"time":12}"#.utf8))
        #expect(partial.isEnabled && partial.coverage == 0.8 && partial.time == 12)
        #expect(partial.density == VolumetricClouds3D().density && partial.seed == VolumetricClouds3D().seed)
    }

    @Test func settingsRoundTripAndFlatAccessors() throws {
        var environment = Environment3D()
        environment.atmosphereEnabled = true
        environment.cloudsEnabled = true
        environment.cloudCoverage = 0.7
        environment.atmosphere.clouds.seed = 99
        environment.atmosphere.clouds.time = 4
        environment.atmosphere.clouds.quality = .high
        let decoded = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(decoded.atmosphere == environment.atmosphere)
        #expect(decoded.cloudsEnabled && decoded.cloudCoverage == 0.7)
        #expect(decoded.atmosphere.clouds.seed == 99 && decoded.atmosphere.clouds.time == 4)
    }

    @Test func wildValuesAreClamped() {
        let defaults = VolumetricClouds3D()
        let wild = VolumetricClouds3D(
            isEnabled: true, coverage: 9, density: .nan, cloudType: -3, baseAltitudeMeters: -50, thicknessMeters: .infinity,
            windDirection: Vector2(.nan, 1), windSpeed: 1e9, detailScale: -2, lightingScale: 500, ambientScale: .nan, time: .nan
        ).sanitized
        #expect(wild.coverage == 1)
        #expect(wild.density == defaults.density)
        #expect(wild.cloudType == 0)
        #expect(wild.baseAltitudeMeters == 0)
        #expect(wild.thicknessMeters == defaults.thicknessMeters)
        #expect(wild.windDirection == defaults.windDirection)
        #expect(wild.windSpeed == 100)
        #expect(wild.detailScale == 0.1)
        #expect(wild.lightingScale == 10)
        #expect(wild.ambientScale == defaults.ambientScale)
        #expect(wild.time == nil, "A non-finite time falls back to the engine clock")
    }

    @Test func aThinOrZeroDirectionIsReplaced() {
        let defaults = VolumetricClouds3D()
        #expect(VolumetricClouds3D(windDirection: .zero).sanitized.windDirection == defaults.windDirection)
        let scaled = VolumetricClouds3D(windDirection: Vector2(0, 5)).sanitized.windDirection
        #expect(abs((scaled.x * scaled.x + scaled.y * scaled.y).squareRoot() - 1) < 1e-5 && scaled.y > 0.99)
        #expect(VolumetricClouds3D(thicknessMeters: 1).sanitized.thicknessMeters == 100)
    }

    @Test func changesImageNeedsEnabledCoverageAndDensity() {
        #expect(VolumetricClouds3D(isEnabled: true).changesImage)
        #expect(!VolumetricClouds3D(isEnabled: false).changesImage)
        #expect(!VolumetricClouds3D(isEnabled: true, coverage: 0).changesImage)
        #expect(!VolumetricClouds3D(isEnabled: true, density: 0).changesImage)
        #expect(!VolumetricClouds3D(isEnabled: true, density: -1).changesImage)
    }

    @Test func cloudsNeedAnEnabledAtmosphere() {
        let clouds = VolumetricClouds3D(isEnabled: true)
        #expect(Atmosphere3D(isEnabled: true, clouds: clouds).cloudsActive)
        #expect(!Atmosphere3D(isEnabled: false, clouds: clouds).cloudsActive)
        #expect(!Atmosphere3D(isEnabled: true, intensity: 0, clouds: clouds).cloudsActive)
        #expect(!Atmosphere3D(isEnabled: true, clouds: VolumetricClouds3D(isEnabled: false)).cloudsActive)
    }

    @Test func tiersGrowWithQuality() {
        let low = Clouds3DTier.tier(for: .low)
        let medium = Clouds3DTier.tier(for: .medium)
        let high = Clouds3DTier.tier(for: .high)
        #expect(low.isLayer && !medium.isLayer && !high.isLayer, "Only the low tier is a 2D layer")
        #expect(low.viewSteps == 0 && low.lightSteps == 0, "A layer does not march")
        #expect(medium.viewSteps < high.viewSteps && medium.lightSteps < high.lightSteps)
        #expect(low.resolutionScale < medium.resolutionScale && medium.resolutionScale < high.resolutionScale)
        #expect(high.viewSteps <= 96 && high.lightSteps <= 8, "The shader loops are capped at 96 and 8")
        #expect(medium.size(for: SizeInt(width: 1920, height: 1080)) == SizeInt(width: 960, height: 540), "Medium renders a quarter of the pixels")
        #expect(medium.size(for: SizeInt(width: 1, height: 1)) == SizeInt(width: 1, height: 1))
    }

    @Test func uniformCarriesTheLayerWindAndSteps() {
        let clouds = VolumetricClouds3D(
            isEnabled: true, coverage: 0.7, density: 2, cloudType: 0.25, baseAltitudeMeters: 2_000, thicknessMeters: 3_000,
            windDirection: Vector2(0, 1), windSpeed: 5, detailScale: 1.5, lightingScale: 1.2, ambientScale: 0.8
        ).sanitized
        let tier = Clouds3DTier.tier(for: .high)
        let packed = Clouds3DUniform(clouds: clouds, tier: tier, time: 100, frame: 19, reset: true, previousViewProjection: .identity)
        #expect(packed.shape == Vector4(0.7, 2, 0.25, 1.5))
        #expect(packed.layer == Vector4(2_000, 3_000, 1.2, 0.8))
        #expect(packed.wind == Vector4(0, 500, Float(tier.viewSteps), Float(tier.lightSteps)))
        #expect(packed.frame == Vector4(3, 1, 0, 0), "The frame index wraps at 16 and the reset flag is set")
        let resolve = CloudResolveUniform(clouds: clouds, reset: false, previousViewProjection: .identity)
        #expect(resolve.parameters == Vector4(CloudResolveUniform.historyWeight, 0, 2_000, 3_000))
    }

    @Test func theKeyIsOnlyTheTierAndTheSize() {
        let tier = Clouds3DTier.tier(for: .medium)
        let size = SizeInt(width: 100, height: 100)
        let key = Clouds3DKey(tier: tier, size: size)
        #expect(Clouds3DKey(tier: tier, size: size) == key)
        #expect(Clouds3DKey(tier: Clouds3DTier.tier(for: .high), size: size) != key)
        #expect(Clouds3DKey(tier: Clouds3DTier.tier(for: .low), size: size) != key)
        #expect(Clouds3DKey(tier: tier, size: SizeInt(width: 101, height: 100)) != key)
    }

    @Test func sanitizingTheAtmosphereSanitizesItsClouds() {
        let atmosphere = Atmosphere3D(isEnabled: true, clouds: VolumetricClouds3D(isEnabled: true, coverage: 5)).sanitized
        #expect(atmosphere.clouds.coverage == 1)
    }
}

extension Render3DGPUTests {
    /// The procedural noise the clouds are made from, generated on the GPU from a seed.
    @Suite("Cloud noise", .enabled(if: GoldenFrame.isEnabled))
    @MainActor
    struct CloudNoise {
        struct Atlases {
            var shape: Image
            var detail: Image
            var weather: Image
        }

        /// Fills fresh textures for `seed` and reads them back.
        private static func generate(seed: UInt32) async throws -> Atlases {
            let scene = try await DebugViews.makeScene()
            let device = scene.device
            let pipelines = Clouds3DNoisePipelines(device: device)
            var cache = Clouds3DNoiseCache()
            let textures = cache.textures(forSeed: seed)
            let command = device.createCommandQueue().makeCommandBuffer()
            pipelines.encode(seed: seed, into: textures, command: command, device: device)
            command.commit()
            return Atlases(
                shape: try #require(try await device.readImage(from: textures.shape)),
                detail: try #require(try await device.readImage(from: textures.detail)),
                weather: try #require(try await device.readImage(from: textures.weather))
            )
        }

        private static func channel(_ color: Color, _ index: Int) -> Float {
            [color.red, color.green, color.blue, color.alpha][index]
        }

        private static func differingPixels(_ a: Image, _ b: Image) -> Int {
            var count = 0
            for y in 0..<a.height {
                for x in 0..<a.width where a.getPixel(x: x, y: y) != b.getPixel(x: x, y: y) { count += 1 }
            }
            return count
        }

        /// Mean and standard deviation of one channel over a rectangle.
        private static func statistics(_ image: Image, channel index: Int, x: Range<Int>, y: Range<Int>) -> (mean: Float, deviation: Float, saturated: Float) {
            var values: [Float] = []
            for row in y {
                for column in x { values.append(channel(image.getPixel(x: column, y: row), index)) }
            }
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
            let saturated = Float(values.filter { $0 < 0.004 || $0 > 0.996 }.count) / Float(values.count)
            return (mean, variance.squareRoot(), saturated)
        }

        @Test
        func theSameSeedGivesTheSamePixels() async throws {
            let first = try await Self.generate(seed: 7)
            let second = try await Self.generate(seed: 7)
            #expect(Self.differingPixels(first.shape, second.shape) == 0)
            #expect(Self.differingPixels(first.detail, second.detail) == 0)
            #expect(Self.differingPixels(first.weather, second.weather) == 0)
        }

        @Test
        func aDifferentSeedGivesDifferentNoise() async throws {
            let first = try await Self.generate(seed: 7)
            let other = try await Self.generate(seed: 8)
            let total = first.weather.width * first.weather.height
            #expect(Self.differingPixels(first.weather, other.weather) > total / 2, "Seeds 7 and 8 must not give the same weather map")
            let shapeTotal = first.shape.width * first.shape.height
            #expect(Self.differingPixels(first.shape, other.shape) > shapeTotal / 2, "Seeds 7 and 8 must not give the same shape noise")
        }

        @Test
        func everyChannelCarriesVariationWithoutSaturating() async throws {
            let atlases = try await Self.generate(seed: 3)
            for (name, image, channels) in [("shape", atlases.shape, 4), ("detail", atlases.detail, 3), ("weather", atlases.weather, 3)] {
                for index in 0..<channels {
                    let stats = Self.statistics(image, channel: index, x: 0..<image.width, y: 0..<image.height)
                    #expect(stats.deviation > 0.05, "\(name) channel \(index) is nearly constant: deviation \(stats.deviation)")
                    #expect(stats.saturated < 0.35, "\(name) channel \(index) is clipped at 0 or 1 for \(stats.saturated) of its texels")
                    #expect(stats.mean > 0.05 && stats.mean < 0.95, "\(name) channel \(index) has mean \(stats.mean)")
                }
            }
        }

        /// A tileable texture has no seam: texels across the wrap-around edge differ no more than neighbours do elsewhere.
        @Test
        func theWeatherMapTilesInBothDirections() async throws {
            let image = try await Self.generate(seed: 5).weather
            for index in 0..<3 {
                var neighbour: Float = 0
                var acrossX: Float = 0
                var acrossY: Float = 0
                for k in 0..<image.height {
                    neighbour += abs(Self.channel(image.getPixel(x: 100, y: k), index) - Self.channel(image.getPixel(x: 101, y: k), index))
                    acrossX += abs(Self.channel(image.getPixel(x: 0, y: k), index) - Self.channel(image.getPixel(x: image.width - 1, y: k), index))
                    acrossY += abs(Self.channel(image.getPixel(x: k, y: 0), index) - Self.channel(image.getPixel(x: k, y: image.height - 1), index))
                }
                #expect(acrossX < neighbour * 2, "Channel \(index) has a seam across the left and right edges: \(acrossX) against \(neighbour)")
                #expect(acrossY < neighbour * 2, "Channel \(index) has a seam across the top and bottom edges: \(acrossY) against \(neighbour)")
            }
        }

        /// The shape noise tiles in x and y inside a slice and in z across the first and last slices.
        @Test
        func theShapeNoiseTilesInAllThreeDimensions() async throws {
            let image = try await Self.generate(seed: 5).shape
            let atlas = Clouds3DNoiseLayout.shape
            func texel(slice: Int, x: Int, y: Int, channel index: Int) -> Float {
                let column = slice % atlas.columns
                let row = slice / atlas.columns
                return Self.channel(image.getPixel(x: column * atlas.tile + x, y: row * atlas.tile + y), index)
            }
            for index in 0..<4 {
                var neighbour: Float = 0
                var acrossX: Float = 0
                var acrossY: Float = 0
                var acrossZ: Float = 0
                var adjacentZ: Float = 0
                for k in 0..<atlas.tile {
                    neighbour += abs(texel(slice: 10, x: 20, y: k, channel: index) - texel(slice: 10, x: 21, y: k, channel: index))
                    acrossX += abs(texel(slice: 10, x: 0, y: k, channel: index) - texel(slice: 10, x: atlas.tile - 1, y: k, channel: index))
                    acrossY += abs(texel(slice: 10, x: k, y: 0, channel: index) - texel(slice: 10, x: k, y: atlas.tile - 1, channel: index))
                    for x in stride(from: 0, to: atlas.tile, by: 8) {
                        acrossZ += abs(texel(slice: 0, x: x, y: k, channel: index) - texel(slice: atlas.slices - 1, x: x, y: k, channel: index))
                        adjacentZ += abs(texel(slice: 0, x: x, y: k, channel: index) - texel(slice: 1, x: x, y: k, channel: index))
                    }
                }
                #expect(acrossX < neighbour * 2, "Shape channel \(index) has an x seam: \(acrossX) against \(neighbour)")
                #expect(acrossY < neighbour * 2, "Shape channel \(index) has a y seam: \(acrossY) against \(neighbour)")
                #expect(acrossZ < adjacentZ * 2, "Shape channel \(index) has a z seam: \(acrossZ) against \(adjacentZ)")
            }
        }

        @Test
        func noiseIsGeneratedOncePerSeedAndTheCacheIsBounded() async throws {
            _ = try await DebugViews.makeScene()
            var cache = Clouds3DNoiseCache()
            _ = cache.textures(forSeed: 1)
            let first = cache.claimBuild(seed: 1)
            let again = cache.claimBuild(seed: 1)
            _ = cache.textures(forSeed: 2)
            let second = cache.claimBuild(seed: 2)
            #expect(first && !again && second)
            #expect(cache.seedCount == 2)
            #expect(cache.memoryBytes == 2 * Clouds3DNoiseLayout.memoryBytes)
            cache.retain(seeds: [2])
            #expect(cache.seedCount == 1 && cache.textures(seed: 1) == nil && cache.textures(seed: 2) != nil)
            for seed in UInt32(10)..<UInt32(10 + Clouds3DNoiseCache.capacity + 3) {
                _ = cache.textures(forSeed: seed)
            }
            #expect(cache.seedCount == Clouds3DNoiseCache.capacity, "The least recently used seeds are dropped")
            #expect(cache.textures(seed: UInt32(10 + Clouds3DNoiseCache.capacity + 2)) != nil)
        }

        @Test
        func theLayoutMatchesTheShaderConstants() {
            #expect(Clouds3DNoiseLayout.shape.size == SizeInt(width: 512, height: 512))
            #expect(Clouds3DNoiseLayout.detail.size == SizeInt(width: 256, height: 128))
            #expect(Clouds3DNoiseLayout.weather.size == SizeInt(width: 256, height: 256))
            #expect(Clouds3DNoiseLayout.memoryBytes == (512 * 512 + 256 * 128 + 256 * 256) * 4)
        }

        @Test
        func theSeedIsMixedSoNeighbouringSeedsDiffer() {
            let mixed = (UInt32(0)..<UInt32(64)).map { CloudNoiseUniform.mix($0) }
            #expect(Set(mixed).count == 64, "The mix must be injective on small seeds")
            #expect(mixed.allSatisfy { $0 != 0 })
            let seed = CloudNoiseUniform(seed: 3, atlas: Clouds3DNoiseLayout.shape).seed
            #expect(UInt32(seed.x) | (UInt32(seed.y) << 16) == CloudNoiseUniform.mix(3), "The seed travels as two exact 16-bit halves")
        }
    }
}

extension Render3DGPUTests {
    /// The clouds seen through the real composite pass.
    @Suite("Cloud frames", .enabled(if: GoldenFrame.isEnabled))
    @MainActor
    struct CloudFrames {
        /// Rotation about X in radians; the light shines along +Z, so +pi/2 puts the sun overhead.
        static let noon: Float = 1.2
        static let lowSun: Float = .pi - 0.2

        /// Yaw about Y applied after a pitch about X, as a quaternion.
        static func orientation(look: Float, yaw: Float) -> Quat {
            let a = Quat(axis: Vector3(0, 1, 0), angle: yaw)
            let b = Quat(axis: Vector3(1, 0, 0), angle: look)
            return Quat(
                x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
            )
        }

        static func scene(
            coverage: Float = 0.6, sun: Float = CloudFrames.noon, look: Float = -0.55, clouds: Bool = true, seed: UInt32 = 1,
            time: Float = 30, atmosphere: Bool = true, quality: CloudQuality3D = .medium, height: Float = 2,
            wind: Vector2 = Vector2(1, 0), windSpeed: Float = 10, yaw: Float = 0
        ) async throws -> DebugViews.Scene {
            let scene = try await DebugViews.makeScene()
            scene.sun.components[Transform.self] = Transform(rotation: Quat(axis: Vector3(1, 0, 0), angle: sun))
            try scene.configure { environment in
                environment.atmosphere = Atmosphere3D(isEnabled: atmosphere)
                environment.atmosphere.clouds = VolumetricClouds3D(isEnabled: clouds, coverage: coverage, windDirection: wind, windSpeed: windSpeed, time: time, seed: seed, quality: quality)
            }
            scene.camera.components[Transform.self] = Transform(rotation: Self.orientation(look: look, yaw: yaw), position: [0, height, -3.4])
            return scene
        }

        private static func luminance(_ color: Color) -> Float {
            0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        }

        private static func differing(_ a: Image, _ b: Image, rows: Range<Int>, threshold: Float = 0) -> Int {
            var count = 0
            for y in rows {
                for x in 0..<a.width {
                    let p = a.getPixel(x: x, y: y)
                    let q = b.getPixel(x: x, y: y)
                    if threshold == 0 ? p != q : abs(p.red - q.red) + abs(p.green - q.green) + abs(p.blue - q.blue) > threshold { count += 1 }
                }
            }
            return count
        }

        private static func cloudViews(_ scene: DebugViews.Scene) throws -> Clouds3DViews {
            let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            return try #require(renderWorld.getResource(Clouds3DViews.self))
        }

        @Test
        func cloudsChangeTheSkyAndLeaveGeometryAlone() async throws {
            let with = try await Self.scene(sun: Self.lowSun, look: -0.15).render(.none, frames: 10)
            let without = try await Self.scene(sun: Self.lowSun, look: -0.15, clouds: false).render(.none, frames: 10)
            let sky = Self.differing(with, without, rows: 0..<280, threshold: 0.02)
            let geometry = Self.differing(with, without, rows: 380..<with.height)
            #expect(sky > 8_000, "Clouds must visibly change the sky: \(sky) pixels")
            #expect(geometry == 0, "Clouds are drawn over the sky only; \(geometry) geometry pixels changed")
        }

        @Test
        func coverageGrowsTheCloudedAreaFromNothing() async throws {
            let clear = try await Self.scene(coverage: 0, clouds: true).render(.none, frames: 10)
            let baseline = try await Self.scene(clouds: false).render(.none, frames: 10)
            #expect(Self.differing(clear, baseline, rows: 0..<clear.height) == 0, "Zero coverage must draw no clouds")
            var covered: [Int] = []
            for coverage in [Float(0.35), 0.6, 0.9] {
                let image = try await Self.scene(coverage: coverage).render(.none, frames: 10)
                covered.append(Self.differing(image, baseline, rows: 0..<430, threshold: 0.04))
            }
            #expect(covered[0] < covered[1] && covered[1] < covered[2], "More coverage must cloud more of the sky: \(covered)")
            #expect(covered[2] > 100_000, "Heavy coverage must cloud most of the sky: \(covered[2])")
        }

        @Test
        func theSameSettingsGiveTheSameFrame() async throws {
            let a = try await Self.scene().render(.none, frames: 8)
            let b = try await Self.scene().render(.none, frames: 8)
            #expect(Self.differing(a, b, rows: 0..<a.height) == 0)
        }

        @Test
        func theSeedAndTheTimeChangeTheClouds() async throws {
            let base = try await Self.scene().render(.none, frames: 8)
            let reseeded = try await Self.scene(seed: 2).render(.none, frames: 8)
            let later = try await Self.scene(time: 600).render(.none, frames: 8)
            #expect(Self.differing(base, reseeded, rows: 0..<430, threshold: 0.03) > 20_000, "Another seed must give other clouds")
            #expect(Self.differing(base, later, rows: 0..<430, threshold: 0.03) > 20_000, "Wind must move the clouds over time")
        }

        @Test
        func cloudsNeedTheAtmosphere() async throws {
            let with = try await Self.scene(atmosphere: false).render(.none, frames: 8)
            let without = try await Self.scene(clouds: false, atmosphere: false).render(.none, frames: 8)
            #expect(Self.differing(with, without, rows: 0..<with.height) == 0, "Clouds are ignored while the atmosphere is off")
        }

        @Test
        func aStillCameraHasAStableImage() async throws {
            let scene = try await Self.scene()
            let early = try await scene.render(.none, frames: 20)
            let late = try await scene.render(.none, frames: 1)
            var change: Float = 0
            for y in stride(from: 0, to: 430, by: 3) {
                for x in stride(from: 0, to: early.width, by: 3) {
                    change += abs(Self.luminance(early.getPixel(x: x, y: y)) - Self.luminance(late.getPixel(x: x, y: y)))
                }
            }
            let mean = change / Float(143 * 214)
            #expect(mean < 0.004, "A still camera under pinned time must not shimmer: mean luminance change \(mean)")
        }

        @Test
        func cloudResourcesExistOnlyWhileCloudsDraw() async throws {
            let off = try await Self.scene(clouds: false)
            _ = try await off.render(.none, frames: 4)
            #expect(try Self.cloudViews(off).memoryBytes == 0, "A camera without clouds holds no cloud texture and no noise")
            let on = try await Self.scene()
            _ = try await on.render(.none, frames: 4)
            #expect(try Self.cloudViews(on).memoryBytes > 0)
            try on.configure { $0.atmosphere.clouds.isEnabled = false }
            _ = try await on.render(.none, frames: 2)
            #expect(try Self.cloudViews(on).store.viewCount == 0, "Turning the clouds off releases the camera's targets")
        }

        @Test
        func theHistoryResetsOnCutsTiersAndSizesButSurvivesLookChanges() async throws {
            _ = try await DebugViews.makeScene()
            var store = Clouds3DViewStore()
            let view: Entity.ID = 1
            let tier = Clouds3DTier.tier(for: .medium)
            let size = SizeInt(width: 320, height: 240)
            let key = Clouds3DKey(tier: tier, size: size)
            func begin(_ key: Clouds3DKey, position: Vector3 = .zero, forward: Vector3 = [0, 0, 1]) -> Clouds3DFrame {
                store.begin(view: view, key: key, position: position, forward: forward, viewProjection: .identity)
            }
            let first = begin(key)
            let copyBeforeSecond = store
            let second = begin(key, position: [5, 0, 0])
            let third = begin(key, position: [5, 0, 0])
            let jumped = begin(key, position: [9_000, 0, 0])
            let turned = begin(key, position: [9_000, 0, 0], forward: [0, 0, -1])
            let newTier = begin(Clouds3DKey(tier: Clouds3DTier.tier(for: .high), size: size), position: [9_000, 0, 0], forward: [0, 0, -1])
            let resized = begin(Clouds3DKey(tier: Clouds3DTier.tier(for: .high), size: SizeInt(width: 640, height: 480)), position: [9_000, 0, 0], forward: [0, 0, -1])
            #expect(first.reset && !second.reset && !third.reset, "Only the first frame starts without history")
            #expect(jumped.reset && turned.reset, "A cut in position or direction discards the history")
            #expect(newTier.reset && resized.reset, "A new tier or size discards the history")
            #expect(second.write === first.read && second.read === first.write, "The history textures alternate")
            #expect(first.output === second.output && second.output === third.output, "The composite reads one fixed texture per view")
            #expect(copyBeforeSecond.output(view: view) === second.output, "A copy of the store taken before this frame's begin still reaches this frame's output")
            #expect(first.frameIndex == 0 && second.frameIndex == 1 && third.frameIndex == 2)
            #expect(store.output(view: view) === resized.output && store.viewCount == 1)
            #expect(newTier.output !== third.output && resized.output !== newTier.output, "New targets get a new display texture")
            store.discard(view: view)
            #expect(store.viewCount == 0 && store.memoryBytes == 0)
        }

        @Test
        func retiredTexturesAreReleasedAfterTheFramesInFlight() async throws {
            _ = try await DebugViews.makeScene()
            var views = Clouds3DViewStore()
            var noise = Clouds3DNoiseCache()
            let key = Clouds3DKey(tier: Clouds3DTier.tier(for: .medium), size: SizeInt(width: 64, height: 64))
            _ = views.begin(view: 1, key: key, position: .zero, forward: [0, 0, 1], viewProjection: .identity)
            views.discard(view: 1)
            _ = noise.textures(forSeed: 1)
            noise.retain(seeds: [])
            #expect(views.retiredCount == 4 && noise.retiredCount == 3, "Discarded textures wait for frames in flight")
            let frames = max(1, unsafe RenderEngine.configurations.maxFramesInFlight) + 2
            for _ in 0..<frames {
                views.advanceFrame()
                noise.advanceFrame()
            }
            #expect(views.retiredCount == 0 && noise.retiredCount == 0, "They are released once no frame in flight can read them")
        }

        /// The horizontal shift, in pixels, that best maps `first` onto `second` over the sky rows.
        private static func bestShift(from first: Image, to second: Image) -> Int {
            var best = 0
            var bestError = Float.infinity
            for shift in stride(from: -240, through: 240, by: 4) {
                var error: Float = 0
                var count: Float = 0
                for y in stride(from: 30, to: 300, by: 6) {
                    for x in stride(from: 260, to: 380, by: 2) {
                        let source = x - shift
                        guard source >= 0, source < first.width else { continue }
                        error += abs(luminance(first.getPixel(x: source, y: y)) - luminance(second.getPixel(x: x, y: y)))
                        count += 1
                    }
                }
                if error / count < bestError {
                    bestError = error / count
                    best = shift
                }
            }
            return best
        }

        @Test
        func theCloudsDriftTowardTheWindDirection() async throws {
            // The camera looks along +Z and +X is to its right, so a wind toward +X must carry the clouds to the right.
            let early = try await Self.scene(look: -1.0, time: 0, windSpeed: 20).render(.none, frames: 10)
            let late = try await Self.scene(look: -1.0, time: 40, windSpeed: 20).render(.none, frames: 10)
            let toward = Self.bestShift(from: early, to: late)
            #expect(toward > 0, "Clouds must move toward +X on screen for a +X wind, shift \(toward)")
            let reversed = try await Self.scene(look: -1.0, time: 40, wind: Vector2(-1, 0), windSpeed: 20).render(.none, frames: 10)
            let against = Self.bestShift(from: early, to: reversed)
            #expect(against < 0, "A -X wind must carry them to the left, shift \(against)")
        }

        @Test
        func cloudsStillDrawInsideAndAboveTheLayer() async throws {
            // The layer spans 1,500 m to 4,000 m. From inside it only rays that do not point at the ground draw clouds.
            for (name, height, look) in [("inside", Float(2_600), Float(-0.45)), ("above", 6_000, 0.0)] {
                let with = try await Self.scene(look: look, height: height).render(.none, frames: 10)
                let without = try await Self.scene(look: look, clouds: false, height: height).render(.none, frames: 10)
                let changed = Self.differing(with, without, rows: 0..<with.height, threshold: 0.02)
                #expect(changed > 4_000, "A camera \(name) the layer must still see clouds: \(changed) pixels")
                var finite = true
                for y in stride(from: 0, to: with.height, by: 8) {
                    for x in stride(from: 0, to: with.width, by: 8) {
                        let pixel = with.getPixel(x: x, y: y)
                        if !(pixel.red.isFinite && pixel.green.isFinite && pixel.blue.isFinite) { finite = false }
                    }
                }
                #expect(finite, "No NaN may reach the frame \(name) the layer")
            }
        }

        @Test
        func aTurningCameraTracksTheCloudsWithoutTrails() async throws {
            let moving = try await Self.scene(look: -0.8, yaw: 0)
            _ = try await moving.render(.none, frames: 12)
            for step in 1...8 {
                moving.camera.components[Transform.self] = Transform(
                    rotation: Self.orientation(look: -0.8, yaw: Float(step) * 0.04), position: [0, 2, -3.4]
                )
                _ = try await moving.render(.none, frames: 1)
            }
            let tracked = try await moving.render(.none, frames: 1)
            let reference = try await Self.scene(look: -0.8, yaw: 0.32).render(.none, frames: 14)
            var change: Float = 0
            var samples: Float = 0
            for y in stride(from: 0, to: 430, by: 3) {
                for x in stride(from: 0, to: tracked.width, by: 3) {
                    change += abs(Self.luminance(tracked.getPixel(x: x, y: y)) - Self.luminance(reference.getPixel(x: x, y: y)))
                    samples += 1
                }
            }
            let mean = change / samples
            #expect(mean < 0.02, "After a turn the clouds must match a settled frame at the same pose: mean luminance difference \(mean)")
        }

        @Test
        func theLowTierDrawsAShadedLayerOverTheSkyOnly() async throws {
            let with = try await Self.scene(sun: Self.lowSun, look: -0.15, quality: .low).render(.none, frames: 10)
            let without = try await Self.scene(sun: Self.lowSun, look: -0.15, clouds: false).render(.none, frames: 10)
            #expect(Self.differing(with, without, rows: 0..<280, threshold: 0.02) > 4_000, "The low tier must still show clouds")
            #expect(Self.differing(with, without, rows: 380..<with.height) == 0, "The layer is drawn over the sky only")
            var covered: [Int] = []
            let baseline = try await Self.scene(clouds: false).render(.none, frames: 10)
            for coverage in [Float(0.3), 0.6, 0.9] {
                let image = try await Self.scene(coverage: coverage, quality: .low).render(.none, frames: 10)
                covered.append(Self.differing(image, baseline, rows: 0..<430, threshold: 0.04))
            }
            #expect(covered[0] < covered[1] && covered[1] < covered[2], "More coverage must cloud more of the sky: \(covered)")
        }

        @Test
        func theLowTierHoldsLessMemoryAndNeverMarches() async throws {
            var bytes: [Int] = []
            for quality in [CloudQuality3D.low, .medium, .high] {
                let scene = try await Self.scene(quality: quality)
                _ = try await scene.render(.none, frames: 4)
                bytes.append(try Self.cloudViews(scene).store.memoryBytes)
            }
            #expect(bytes[0] < bytes[1] && bytes[1] < bytes[2], "Cloud target memory must grow with the tier: \(bytes)")
        }

        @Test
        func skyFramesMatchTheirGoldenReferences() async throws {
            for (name, sun, look, quality) in [("clouds-noon", Self.noon, Float(-0.55), CloudQuality3D.medium), ("clouds-low-sun", Self.lowSun, Float(-0.15), .medium), ("clouds-low-tier", Self.noon, Float(-0.55), .low), ("clouds-high-tier", Self.noon, Float(-0.55), .high)] {
                let image = try await Self.scene(sun: sun, look: look, quality: quality).render(.none, frames: 10)
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
