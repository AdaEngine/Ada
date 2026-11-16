//
//  Atmosphere3DResources.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import Math

/// Uniform block shared by every atmosphere pass. Mirrors `Atmosphere3DUniform` in `atmosphere_common.wgsl`.
struct Atmosphere3DUniform: Sendable {
    var inverseView: Transform3D
    var inverseProjection: Transform3D
    var sunDirection: Vector4
    var sunIlluminance: Vector4
    var rayleigh: Vector4
    var mie: Vector4
    var ozone: Vector4
    var planet: Vector4
    var aerial: Vector4
    var steps: Vector4
    var tables: Vector4
}

/// Per-quality march lengths and table sizes. The multiple-scattering table is 32 by 32 in every tier.
struct Atmosphere3DTier: Equatable, Sendable {
    var transmittanceSteps: Int
    var multiScatterSteps: Int
    var skyViewSteps: Int
    var aerialSteps: Int
    var transmittanceSize: SizeInt
    var skyViewSize: SizeInt
    /// Width and height of one aerial-perspective depth slice, in texels.
    var aerialTile: Int
    var aerialSlices: Int

    /// The aerial-perspective atlas lays its slices side by side.
    var aerialSize: SizeInt { SizeInt(width: aerialTile * aerialSlices, height: aerialTile) }

    static func tier(for quality: AtmosphereQuality3D) -> Atmosphere3DTier {
        switch quality {
        case .low:
            Atmosphere3DTier(
                transmittanceSteps: 24, multiScatterSteps: 10, skyViewSteps: 16, aerialSteps: 8,
                transmittanceSize: SizeInt(width: 128, height: 32), skyViewSize: SizeInt(width: 96, height: 54), aerialTile: 16, aerialSlices: 8
            )
        case .medium:
            Atmosphere3DTier(
                transmittanceSteps: 40, multiScatterSteps: 20, skyViewSteps: 30, aerialSteps: 16,
                transmittanceSize: SizeInt(width: 256, height: 64), skyViewSize: SizeInt(width: 192, height: 108), aerialTile: 32, aerialSlices: 16
            )
        case .high:
            Atmosphere3DTier(
                transmittanceSteps: 64, multiScatterSteps: 32, skyViewSteps: 48, aerialSteps: 24,
                transmittanceSize: SizeInt(width: 256, height: 64), skyViewSize: SizeInt(width: 256, height: 144), aerialTile: 32, aerialSlices: 24
            )
        }
    }
}

/// Everything the transmittance and multiple-scattering tables depend on. Sun and camera are not part of it, so
/// moving either never rebuilds them.
struct Atmosphere3DStaticKey: Equatable, Sendable {
    var rayleighScale: Float
    var mieScale: Float
    var ozoneScale: Float
    var groundAlbedo: Float
    var groundRadius: Float
    var atmosphereHeight: Float
    var tier: Atmosphere3DTier
}

extension Atmosphere3DUniform {
    /// `atmosphere` must already be sanitized. `sunDirection` points toward the sun.
    init(
        atmosphere: Atmosphere3D,
        sunDirection: Vector3,
        sunRadiance: Vector3,
        inverseView: Transform3D,
        inverseProjection: Transform3D,
        cameraAltitude: Float
    ) {
        let tier = Atmosphere3DTier.tier(for: atmosphere.quality)
        let mieScattering = Self.mieScattering * atmosphere.mieScale
        self.init(
            inverseView: inverseView, inverseProjection: inverseProjection,
            sunDirection: Vector4(sunDirection.normalized, 0),
            sunIlluminance: Vector4(sunRadiance * atmosphere.intensity, atmosphere.intensity),
            rayleigh: Vector4(Self.rayleighScattering * atmosphere.rayleighScale, Self.rayleighScaleHeight),
            mie: Vector4(mieScattering, mieScattering + Self.mieAbsorption * atmosphere.mieScale, Self.mieScaleHeight, atmosphere.mieAnisotropy),
            ozone: Vector4(Self.ozoneAbsorption * atmosphere.ozoneScale, 0),
            planet: Vector4(
                atmosphere.groundRadiusMeters, atmosphere.groundRadiusMeters + atmosphere.atmosphereHeightMeters,
                atmosphere.groundAlbedo, max(cameraAltitude, 0)
            ),
            aerial: Vector4(
                atmosphere.aerialPerspectiveMaxDistance, atmosphere.aerialPerspectiveScale, Float(tier.aerialSlices), Float(tier.aerialTile)
            ),
            steps: Vector4(Float(tier.transmittanceSteps), Float(tier.skyViewSteps), Float(tier.aerialSteps), Float(tier.multiScatterSteps)),
            tables: Vector4(
                Float(tier.skyViewSize.width), Float(tier.skyViewSize.height), Float(tier.transmittanceSize.width), Float(tier.transmittanceSize.height)
            )
        )
    }

    // Earth-like coefficients per meter (Hillaire 2020).
    static let rayleighScattering = Vector3(5.802e-6, 13.558e-6, 33.1e-6)
    static let rayleighScaleHeight: Float = 8_000
    static let mieScattering: Float = 3.996e-6
    static let mieAbsorption: Float = 4.4e-6
    static let mieScaleHeight: Float = 1_200
    static let ozoneAbsorption = Vector3(0.650e-6, 1.881e-6, 0.085e-6)

    static func staticKey(for atmosphere: Atmosphere3D) -> Atmosphere3DStaticKey {
        Atmosphere3DStaticKey(
            rayleighScale: atmosphere.rayleighScale, mieScale: atmosphere.mieScale, ozoneScale: atmosphere.ozoneScale,
            groundAlbedo: atmosphere.groundAlbedo, groundRadius: atmosphere.groundRadiusMeters,
            atmosphereHeight: atmosphere.atmosphereHeightMeters, tier: .tier(for: atmosphere.quality)
        )
    }
}

/// The sun an atmosphere is lit by: the primary directional light, or the settings' fallback when there is none.
struct Atmosphere3DSun: Sendable, Equatable {
    var direction: Vector3
    var radiance: Vector3

    init(light: ExtractedDirectionalLight3D?, settings: Atmosphere3D) {
        direction = light?.directionToLight.normalized ?? settings.fallbackSunDirection
        radiance = light.map { $0.radiance * $0.intensity } ?? Vector3(1, 1, 1)
    }
}

extension Environment3DUniform {
    /// Base radiance of the sun disc relative to the sun illuminance; `sunDiscIntensity` scales it.
    static let atmosphereSunDiscRadiance: Float = 100
    /// Angular radius of the sun in radians.
    static let atmosphereSunAngularRadius: Float = 0.00465

    /// Fills the composite's atmosphere fields. `atmosphere` must already be sanitized.
    mutating func applyAtmosphere(_ atmosphere: Atmosphere3D, sun: Atmosphere3DSun, cameraAltitude: Float) {
        self.atmosphere = Vector4(
            1, atmosphere.aerialPerspectiveScale, atmosphere.sunDiscIntensity * Self.atmosphereSunDiscRadiance,
            atmosphere.sunDiscScale * Self.atmosphereSunAngularRadius
        )
        atmosphereSun = Vector4(sun.direction, 0)
        atmospherePlanet = Vector4(
            atmosphere.groundRadiusMeters, atmosphere.groundRadiusMeters + atmosphere.atmosphereHeightMeters,
            // The sky-view table is built for a camera at least half a meter above the ground.
            atmosphere.groundRadiusMeters + max(cameraAltitude, 0.5), atmosphere.aerialPerspectiveMaxDistance
        )
        atmosphereIlluminance = Vector4(sun.radiance * atmosphere.intensity, Float(Atmosphere3DTier.tier(for: atmosphere.quality).aerialSlices))
    }
}

/// What the sky-view table depends on besides the medium: the sun and the camera's height. A camera that only turns
/// does not change it.
struct Atmosphere3DSkyKey: Equatable, Sendable {
    var medium: Atmosphere3DStaticKey
    var sunDirection: Vector4
    var sunIlluminance: Vector4
    var anisotropy: Float
    var altitude: Float
}

/// What the aerial-perspective atlas depends on: everything the sky view does, plus the camera's view and projection
/// and the haze range.
struct Atmosphere3DAerialKey: Equatable, Sendable {
    var sky: Atmosphere3DSkyKey
    var inverseView: Transform3D
    var inverseProjection: Transform3D
    var range: Float
}

/// The tables of one camera. The aerial-perspective atlas has one texture for scattered light and one for the
/// per-channel transmittance of the path.
struct Atmosphere3DTables {
    let transmittance: RenderTexture
    let multiScatter: RenderTexture
    let skyView: RenderTexture
    let aerial: RenderTexture
    let aerialTransmittance: RenderTexture

    var all: [RenderTexture] { [transmittance, multiScatter, skyView, aerial, aerialTransmittance] }
}

/// Per-camera tables and the key they were last built for. Holds nothing for a camera that stops using the atmosphere.
struct Atmosphere3DTableStore {
    private struct Entry {
        var tables: Atmosphere3DTables
        var tier: Atmosphere3DTier
        var builtKey: Atmosphere3DStaticKey?
        var skyKey: Atmosphere3DSkyKey?
        var aerialKey: Atmosphere3DAerialKey?
    }

    private var entries: [Entity.ID: Entry] = [:]
    private var retired: [RenderTexture] = []

    var viewCount: Int { entries.count }

    /// Bytes the tables of every view hold on the GPU.
    var memoryBytes: Int {
        entries.values.reduce(0) { total, entry in
            total + entry.tables.all.reduce(0) { $0 + $1.size.width * $1.size.height * Self.bytesPerTexel }
        }
    }

    /// The tables are `rgba_16f`: four half-precision channels.
    private static let bytesPerTexel = 8

    func tables(view: Entity.ID) -> Atmosphere3DTables? { entries[view]?.tables }

    /// The tables of `view` at the sizes of `tier`. A camera whose tier changes gets new tables and rebuilds the static ones.
    mutating func tables(forView view: Entity.ID, tier: Atmosphere3DTier) -> Atmosphere3DTables {
        if let existing = entries[view] {
            if existing.tier == tier { return existing.tables }
            retire(existing.tables)
        }
        func texture(_ size: SizeInt, _ label: String) -> RenderTexture {
            RenderTexture(size: size, scaleFactor: 1, format: .rgba_16f, debugLabel: label)
        }
        let tables = Atmosphere3DTables(
            transmittance: texture(tier.transmittanceSize, "Atmosphere Transmittance"),
            multiScatter: texture(SizeInt(width: 32, height: 32), "Atmosphere Multiple Scattering"),
            skyView: texture(tier.skyViewSize, "Atmosphere Sky View"),
            aerial: texture(tier.aerialSize, "Atmosphere Aerial Perspective"),
            aerialTransmittance: texture(tier.aerialSize, "Atmosphere Aerial Transmittance")
        )
        entries[view] = Entry(tables: tables, tier: tier, builtKey: nil)
        return tables
    }

    /// Whether the transmittance and multiple-scattering tables must be rebuilt for `key`, recording that they were.
    mutating func claimStaticUpdate(view: Entity.ID, key: Atmosphere3DStaticKey) -> Bool {
        guard var entry = entries[view], entry.builtKey != key else { return false }
        entry.builtKey = key
        entries[view] = entry
        return true
    }

    /// Which per-frame tables must be redrawn for this frame's uniform, recording that they were. A table whose inputs did not
    /// change keeps its last contents, so a still camera under a still sun costs nothing here.
    mutating func claimFrameUpdates(view: Entity.ID, uniform: Atmosphere3DUniform, key: Atmosphere3DStaticKey) -> (sky: Bool, aerial: Bool) {
        guard var entry = entries[view] else { return (true, true) }
        let sky = Atmosphere3DSkyKey(
            medium: key, sunDirection: uniform.sunDirection, sunIlluminance: uniform.sunIlluminance,
            anisotropy: uniform.mie.w, altitude: uniform.planet.w
        )
        let aerial = Atmosphere3DAerialKey(
            sky: sky, inverseView: uniform.inverseView, inverseProjection: uniform.inverseProjection, range: uniform.aerial.x
        )
        let result = (sky: entry.skyKey != sky, aerial: entry.aerialKey != aerial)
        entry.skyKey = sky
        entry.aerialKey = aerial
        entries[view] = entry
        return result
    }

    mutating func discard(view: Entity.ID) {
        guard let removed = entries.removeValue(forKey: view) else { return }
        retire(removed.tables)
    }

    /// A frame still in flight may read the tables, so keep them alive a little longer.
    private mutating func retire(_ tables: Atmosphere3DTables) {
        retired.append(contentsOf: tables.all)
        let limit = 5 * (max(1, unsafe RenderEngine.configurations.maxFramesInFlight) + 1)
        if retired.count > limit {
            retired.removeFirst(retired.count - limit)
        }
    }

    mutating func retainViews(_ views: [Entity.ID]) {
        for view in entries.keys where !views.contains(view) {
            discard(view: view)
        }
    }
}

/// The four table pipelines, a clamping sampler and the per-camera tables. The pipelines are created at startup; the
/// tables are created only while a camera uses the atmosphere.
struct Atmosphere3DViews: Resource {
    let transmittancePipeline: RenderPipeline
    let multiScatterPipeline: RenderPipeline
    let skyViewPipeline: RenderPipeline
    let aerialPipeline: RenderPipeline
    let sampler: Sampler
    var uniform = FrameUniformCache3D<Atmosphere3DUniform>()
    var store = Atmosphere3DTableStore()

    init(device: RenderDevice) {
        func pipeline(_ name: String, targets: Int = 1) -> RenderPipeline {
            let shader = CorePipelineShaders.loadRequiredBuiltin("atmosphere_\(name)_3d")
            var descriptor = RenderPipelineDescriptor(
                vertex: shader.asset.requiredShader(for: .vertex),
                fragment: shader.asset.getShader(for: .fragment),
                debugName: "Atmosphere \(name)",
                backfaceCulling: false,
                depthPixelFormat: .none
            )
            descriptor.colorAttachments = (0..<targets).map { _ in .init(format: .rgba_16f) }
            return device.createRenderPipeline(from: descriptor)
        }
        transmittancePipeline = pipeline("transmittance")
        multiScatterPipeline = pipeline("multiscatter")
        skyViewPipeline = pipeline("skyview")
        aerialPipeline = pipeline("aerial", targets: 2)
        sampler = device.createSampler(from: .init(minFilter: .linear, magFilter: .linear, mipFilter: .notMipmapped))
    }

    /// The tables of `view` if the atmosphere ran for it.
    func tables(view: Entity.ID) -> Atmosphere3DTables? {
        store.tables(view: view)
    }

    mutating func retainViews(_ views: [Entity.ID]) {
        store.retainViews(views)
        uniform.retainViews(views)
    }

    mutating func discard(view: Entity.ID) {
        store.discard(view: view)
    }
}
