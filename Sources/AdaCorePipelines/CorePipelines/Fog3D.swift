import AdaRender
import AdaUtils
import Foundation
import Math

/// Axis-aligned local participating medium. Bounds and edge fade are in world units.
public struct LocalFogVolume3D: Codable, Sendable, Equatable {
    public var minimum: Vector3
    public var maximum: Vector3
    public var density: Float
    public var albedo: Vector3
    public var edgeFade: Float
    public init(minimum: Vector3, maximum: Vector3, density: Float = 0.1, albedo: Vector3 = .one, edgeFade: Float = 0.25) {
        self.minimum = minimum; self.maximum = maximum; self.density = density
        self.albedo = albedo; self.edgeFade = edgeFade
    }
    var isValid: Bool {
        minimum.x.isFinite && minimum.y.isFinite && minimum.z.isFinite
            && maximum.x.isFinite && maximum.y.isFinite && maximum.z.isFinite
            && maximum.x > minimum.x && maximum.y > minimum.y && maximum.z > minimum.z
            && density.isFinite && density > 0
    }
}

/// Shadowed sun light shafts marched through the fog medium.
///
/// A half-resolution pass marches each view ray, samples the primary directional light's cascaded shadow map and
/// adds the in-scattered light to the frame before tone mapping. It needs `Fog3D` enabled, whose `density` and
/// height falloff define the medium, and replaces the unshadowed `sunInscattering` glow while it runs.
public struct VolumetricFog3D: Codable, Sendable, Equatable {
    /// Whether the pass runs. Off by default; a disabled effect allocates nothing.
    public var isEnabled: Bool
    /// Strength of the in-scattered sun light, as a multiple of the sun's radiance.
    public var intensity: Float
    /// Henyey-Greenstein anisotropy (`-0.95...0.95`). Positive values brighten shafts when looking toward the sun.
    public var anisotropy: Float
    /// Samples per ray (`4...64`). More samples reduce noise and banding.
    public var steps: Int
    /// Farthest distance marched from the camera. Closer geometry ends the ray earlier.
    public var maxDistance: Float
    /// At most eight local lights are evaluated per ray sample. Zero preserves sun-only shafts.
    public var localLightLimit: Int = 4

    public init(isEnabled: Bool = false, intensity: Float = 1, anisotropy: Float = 0.4, steps: Int = 24, maxDistance: Float = 60) {
        self.isEnabled = isEnabled
        self.intensity = intensity
        self.anisotropy = anisotropy
        self.steps = steps
        self.maxDistance = maxDistance
    }

    private enum CodingKeys: CodingKey { case isEnabled, intensity, anisotropy, steps, maxDistance, localLightLimit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VolumetricFog3D()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? defaults.intensity
        anisotropy = try container.decodeIfPresent(Float.self, forKey: .anisotropy) ?? defaults.anisotropy
        steps = try container.decodeIfPresent(Int.self, forKey: .steps) ?? defaults.steps
        maxDistance = try container.decodeIfPresent(Float.self, forKey: .maxDistance) ?? defaults.maxDistance
        localLightLimit = try container.decodeIfPresent(Int.self, forKey: .localLightLimit) ?? defaults.localLightLimit
    }

    /// Settings clamped to ranges the shader handles, replacing non-finite values with defaults.
    var sanitized: VolumetricFog3D {
        let defaults = VolumetricFog3D()
        var result = VolumetricFog3D(
            isEnabled: isEnabled,
            intensity: finiteRenderValue(intensity, fallback: defaults.intensity, range: 0...16),
            anisotropy: finiteRenderValue(anisotropy, fallback: defaults.anisotropy, range: -0.95...0.95),
            steps: min(max(steps, 4), 64),
            maxDistance: finiteRenderValue(maxDistance, fallback: defaults.maxDistance, range: 1...100_000)
        )
        result.localLightLimit = min(max(localLightLimit, 0), 8)
        return result
    }
}

/// Distance and exponential height fog, applied to lit geometry in linear HDR before exposure and tone mapping.
///
/// Optical depth along a view ray is the integral of `density * exp(-heightFalloff * (y - baseHeight))`, so fog
/// is thickest at and below `baseHeight` and thins out above it. A `heightFalloff` of `0` gives uniform
/// distance fog. Fog scatters ambient light in `color` and, when `sunInscattering` is above zero, brightens
/// towards the primary directional light.
public struct Fog3D: Codable, Sendable, Equatable {
    /// Whether fog is applied. Off by default.
    public var isEnabled: Bool
    /// Fog color authored in sRGB, like the skybox colors.
    public var color: Color
    /// Extinction per world unit at `baseHeight`. `0.02` is light haze; `0.2` is dense fog.
    public var density: Float
    /// How quickly fog thins with height, per world unit. `0` disables the height term.
    public var heightFalloff: Float
    /// World-space height where fog has its full `density`.
    public var baseHeight: Float
    /// Distance from the camera before fog starts.
    public var startDistance: Float
    /// Largest fraction of a pixel that fog can replace (`0...1`).
    public var maximumOpacity: Float
    /// How much fog covers the sky (`0...1`). `0` leaves the sky untouched.
    public var skyInfluence: Float
    /// Strength of the glow towards the directional light, as a multiple of its radiance.
    public var sunInscattering: Float
    /// Tightness of the sun glow. Larger values give a narrower cone.
    public var sunExponent: Float
    /// Shadowed light shafts through this fog.
    public var volumetric: VolumetricFog3D
    /// Up to eight overlapping local boxes, in addition to the global height fog.
    public var localVolumes: [LocalFogVolume3D] = []

    public init(
        isEnabled: Bool = false,
        color: Color = Color(red: 0.62, green: 0.72, blue: 0.82),
        density: Float = 0.02,
        heightFalloff: Float = 0,
        baseHeight: Float = 0,
        startDistance: Float = 0,
        maximumOpacity: Float = 1,
        skyInfluence: Float = 0,
        sunInscattering: Float = 0,
        sunExponent: Float = 8,
        volumetric: VolumetricFog3D = VolumetricFog3D()
    ) {
        self.isEnabled = isEnabled
        self.color = color
        self.density = density
        self.heightFalloff = heightFalloff
        self.baseHeight = baseHeight
        self.startDistance = startDistance
        self.maximumOpacity = maximumOpacity
        self.skyInfluence = skyInfluence
        self.sunInscattering = sunInscattering
        self.sunExponent = sunExponent
        self.volumetric = volumetric
    }

    private enum CodingKeys: CodingKey {
        case isEnabled, color, density, heightFalloff, baseHeight, startDistance, maximumOpacity, skyInfluence, sunInscattering, sunExponent, volumetric, localVolumes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Fog3D()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        color = try container.decodeIfPresent(Color.self, forKey: .color) ?? defaults.color
        density = try container.decodeIfPresent(Float.self, forKey: .density) ?? defaults.density
        heightFalloff = try container.decodeIfPresent(Float.self, forKey: .heightFalloff) ?? defaults.heightFalloff
        baseHeight = try container.decodeIfPresent(Float.self, forKey: .baseHeight) ?? defaults.baseHeight
        startDistance = try container.decodeIfPresent(Float.self, forKey: .startDistance) ?? defaults.startDistance
        maximumOpacity = try container.decodeIfPresent(Float.self, forKey: .maximumOpacity) ?? defaults.maximumOpacity
        skyInfluence = try container.decodeIfPresent(Float.self, forKey: .skyInfluence) ?? defaults.skyInfluence
        sunInscattering = try container.decodeIfPresent(Float.self, forKey: .sunInscattering) ?? defaults.sunInscattering
        sunExponent = try container.decodeIfPresent(Float.self, forKey: .sunExponent) ?? defaults.sunExponent
        volumetric = try container.decodeIfPresent(VolumetricFog3D.self, forKey: .volumetric) ?? defaults.volumetric
        localVolumes = try container.decodeIfPresent([LocalFogVolume3D].self, forKey: .localVolumes) ?? []
    }

    /// Whether fog can change the image. A camera that returns `false` pays nothing for fog.
    var changesImage: Bool {
        let settings = sanitized
        return isEnabled && (settings.density > 0 || settings.localVolumes.contains(where: \.isValid)) && settings.maximumOpacity > 0
    }

    /// Whether the light-shaft pass has work to do.
    var volumetricActive: Bool {
        changesImage && volumetric.isEnabled && volumetric.sanitized.intensity > 0
    }

    /// Settings clamped to ranges the shader handles, replacing non-finite values with defaults.
    var sanitized: Fog3D {
        let defaults = Fog3D()
        var result = Fog3D(
            isEnabled: isEnabled,
            color: color,
            density: finiteRenderValue(density, fallback: defaults.density, range: 0...10),
            heightFalloff: finiteRenderValue(heightFalloff, fallback: defaults.heightFalloff, range: 0...10),
            baseHeight: finiteRenderValue(baseHeight, fallback: defaults.baseHeight, range: -100_000...100_000),
            startDistance: finiteRenderValue(startDistance, fallback: defaults.startDistance, range: 0...100_000),
            maximumOpacity: finiteRenderValue(maximumOpacity, fallback: defaults.maximumOpacity, range: 0...1),
            skyInfluence: finiteRenderValue(skyInfluence, fallback: defaults.skyInfluence, range: 0...1),
            sunInscattering: finiteRenderValue(sunInscattering, fallback: defaults.sunInscattering, range: 0...16),
            sunExponent: finiteRenderValue(sunExponent, fallback: defaults.sunExponent, range: 1...256),
            volumetric: volumetric.sanitized
        )
        result.localVolumes = Array(localVolumes.filter(\.isValid).prefix(8))
        return result
    }
}
