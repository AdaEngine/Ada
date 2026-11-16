//
//  Atmosphere3D.swift
//  AdaEngine
//

import Math

/// How much work the atmosphere does per frame. The default follows the platform.
public enum AtmosphereQuality3D: String, Codable, Sendable, CaseIterable {
    case low, medium, high

    /// `low` in the browser, `medium` everywhere else.
    public static var platformDefault: AtmosphereQuality3D {
        #if arch(wasm32)
        .low
        #else
        .medium
        #endif
    }
}

/// A physically based sky driven by the primary directional light.
public struct Atmosphere3D: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var intensity: Float
    public var rayleighScale: Float
    public var mieScale: Float
    public var mieAnisotropy: Float
    public var ozoneScale: Float
    public var groundAlbedo: Float
    public var groundRadiusMeters: Float
    public var atmosphereHeightMeters: Float
    public var sunDiscScale: Float
    public var sunDiscIntensity: Float
    public var aerialPerspectiveScale: Float
    public var aerialPerspectiveMaxDistance: Float
    public var tintsSunLight: Bool
    public var fallbackSunDirection: Vector3
    public var quality: AtmosphereQuality3D

    public init(
        isEnabled: Bool = false,
        intensity: Float = 1,
        rayleighScale: Float = 1,
        mieScale: Float = 1,
        mieAnisotropy: Float = 0.8,
        ozoneScale: Float = 1,
        groundAlbedo: Float = 0.3,
        groundRadiusMeters: Float = 6_360_000,
        atmosphereHeightMeters: Float = 100_000,
        sunDiscScale: Float = 1,
        sunDiscIntensity: Float = 1,
        aerialPerspectiveScale: Float = 1,
        aerialPerspectiveMaxDistance: Float = 32_000,
        tintsSunLight: Bool = false,
        fallbackSunDirection: Vector3 = Vector3(0.3, 0.8, 0.5).normalized,
        quality: AtmosphereQuality3D = .platformDefault
    ) {
        self.isEnabled = isEnabled
        self.intensity = intensity
        self.rayleighScale = rayleighScale
        self.mieScale = mieScale
        self.mieAnisotropy = mieAnisotropy
        self.ozoneScale = ozoneScale
        self.groundAlbedo = groundAlbedo
        self.groundRadiusMeters = groundRadiusMeters
        self.atmosphereHeightMeters = atmosphereHeightMeters
        self.sunDiscScale = sunDiscScale
        self.sunDiscIntensity = sunDiscIntensity
        self.aerialPerspectiveScale = aerialPerspectiveScale
        self.aerialPerspectiveMaxDistance = aerialPerspectiveMaxDistance
        self.tintsSunLight = tintsSunLight
        self.fallbackSunDirection = fallbackSunDirection
        self.quality = quality
    }

    private enum CodingKeys: CodingKey {
        case isEnabled, intensity, rayleighScale, mieScale, mieAnisotropy, ozoneScale, groundAlbedo, groundRadiusMeters,
             atmosphereHeightMeters, sunDiscScale, sunDiscIntensity, aerialPerspectiveScale, aerialPerspectiveMaxDistance,
             tintsSunLight, fallbackSunDirection, quality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Atmosphere3D()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? defaults.intensity
        rayleighScale = try container.decodeIfPresent(Float.self, forKey: .rayleighScale) ?? defaults.rayleighScale
        mieScale = try container.decodeIfPresent(Float.self, forKey: .mieScale) ?? defaults.mieScale
        mieAnisotropy = try container.decodeIfPresent(Float.self, forKey: .mieAnisotropy) ?? defaults.mieAnisotropy
        ozoneScale = try container.decodeIfPresent(Float.self, forKey: .ozoneScale) ?? defaults.ozoneScale
        groundAlbedo = try container.decodeIfPresent(Float.self, forKey: .groundAlbedo) ?? defaults.groundAlbedo
        groundRadiusMeters = try container.decodeIfPresent(Float.self, forKey: .groundRadiusMeters) ?? defaults.groundRadiusMeters
        atmosphereHeightMeters = try container.decodeIfPresent(Float.self, forKey: .atmosphereHeightMeters) ?? defaults.atmosphereHeightMeters
        sunDiscScale = try container.decodeIfPresent(Float.self, forKey: .sunDiscScale) ?? defaults.sunDiscScale
        sunDiscIntensity = try container.decodeIfPresent(Float.self, forKey: .sunDiscIntensity) ?? defaults.sunDiscIntensity
        aerialPerspectiveScale = try container.decodeIfPresent(Float.self, forKey: .aerialPerspectiveScale) ?? defaults.aerialPerspectiveScale
        aerialPerspectiveMaxDistance = try container.decodeIfPresent(Float.self, forKey: .aerialPerspectiveMaxDistance) ?? defaults.aerialPerspectiveMaxDistance
        tintsSunLight = try container.decodeIfPresent(Bool.self, forKey: .tintsSunLight) ?? defaults.tintsSunLight
        fallbackSunDirection = try container.decodeIfPresent(Vector3.self, forKey: .fallbackSunDirection) ?? defaults.fallbackSunDirection
        quality = try container.decodeIfPresent(AtmosphereQuality3D.self, forKey: .quality) ?? defaults.quality
    }

    /// Whether the atmosphere can change the image. A camera that returns `false` pays nothing for it.
    var changesImage: Bool {
        isEnabled && finiteRenderValue(intensity, fallback: Self().intensity, range: 0...64) > 0
    }

    /// Settings clamped to ranges the shaders handle, replacing non-finite values with defaults.
    var sanitized: Atmosphere3D {
        let defaults = Atmosphere3D()
        var direction = fallbackSunDirection
        let finite = direction.x.isFinite && direction.y.isFinite && direction.z.isFinite
        if !finite || direction.length < 1e-6 {
            direction = defaults.fallbackSunDirection
        } else {
            direction = direction.normalized
        }
        return Atmosphere3D(
            isEnabled: isEnabled,
            intensity: finiteRenderValue(intensity, fallback: defaults.intensity, range: 0...64),
            rayleighScale: finiteRenderValue(rayleighScale, fallback: defaults.rayleighScale, range: 0...10),
            mieScale: finiteRenderValue(mieScale, fallback: defaults.mieScale, range: 0...10),
            mieAnisotropy: finiteRenderValue(mieAnisotropy, fallback: defaults.mieAnisotropy, range: -0.99...0.99),
            ozoneScale: finiteRenderValue(ozoneScale, fallback: defaults.ozoneScale, range: 0...10),
            groundAlbedo: finiteRenderValue(groundAlbedo, fallback: defaults.groundAlbedo, range: 0...1),
            groundRadiusMeters: finiteRenderValue(groundRadiusMeters, fallback: defaults.groundRadiusMeters, range: 1_000...100_000_000),
            atmosphereHeightMeters: finiteRenderValue(atmosphereHeightMeters, fallback: defaults.atmosphereHeightMeters, range: 1_000...1_000_000),
            sunDiscScale: finiteRenderValue(sunDiscScale, fallback: defaults.sunDiscScale, range: 0...10),
            sunDiscIntensity: finiteRenderValue(sunDiscIntensity, fallback: defaults.sunDiscIntensity, range: 0...1_000),
            aerialPerspectiveScale: finiteRenderValue(aerialPerspectiveScale, fallback: defaults.aerialPerspectiveScale, range: 0...10),
            aerialPerspectiveMaxDistance: finiteRenderValue(aerialPerspectiveMaxDistance, fallback: defaults.aerialPerspectiveMaxDistance, range: 1...1_000_000),
            tintsSunLight: tintsSunLight,
            fallbackSunDirection: direction,
            quality: quality
        )
    }
}
