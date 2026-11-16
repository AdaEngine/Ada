//
//  VolumetricClouds3D.swift
//  AdaEngine
//

import Math

/// How much work the clouds do per frame. The default follows the platform.
public enum CloudQuality3D: String, Codable, Sendable, CaseIterable {
    case low, medium, high

    /// `low` in the browser, `medium` everywhere else.
    public static var platformDefault: Self {
        #if arch(wasm32)
        .low
        #else
        .medium
        #endif
    }
}

/// A single layer of procedural clouds that the atmosphere lights. Clouds are ignored unless the atmosphere is enabled.
public struct VolumetricClouds3D: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// Fraction of the sky the layer covers, 0 (clear) to 1 (overcast).
    public var coverage: Float
    /// Opacity multiplier of the cloud material.
    public var density: Float
    /// Shape of the clouds, 0 for flat stratus to 1 for tall cumulus.
    public var cloudType: Float
    public var baseAltitudeMeters: Float
    public var thicknessMeters: Float
    /// Horizontal direction the layer drifts toward (X and Z of the world).
    public var windDirection: Vector2
    public var windSpeed: Float
    /// Scale of the fine detail erosion.
    public var detailScale: Float
    /// Multiplier of the sun's in-scattered light.
    public var lightingScale: Float
    /// Multiplier of the sky light on the clouds.
    public var ambientScale: Float
    /// Seconds. `nil` follows the engine clock; a value pins the layer so frames are deterministic.
    public var time: Float?
    /// Seeds the procedural noise, so the same seed always gives the same clouds.
    public var seed: UInt32
    public var quality: CloudQuality3D

    public init(
        isEnabled: Bool = false,
        coverage: Float = 0.5,
        density: Float = 1,
        cloudType: Float = 0.5,
        baseAltitudeMeters: Float = 1_500,
        thicknessMeters: Float = 2_500,
        windDirection: Vector2 = Vector2(1, 0),
        windSpeed: Float = 10,
        detailScale: Float = 1,
        lightingScale: Float = 1,
        ambientScale: Float = 1,
        time: Float? = nil,
        seed: UInt32 = 1,
        quality: CloudQuality3D = .platformDefault
    ) {
        self.isEnabled = isEnabled
        self.coverage = coverage
        self.density = density
        self.cloudType = cloudType
        self.baseAltitudeMeters = baseAltitudeMeters
        self.thicknessMeters = thicknessMeters
        self.windDirection = windDirection
        self.windSpeed = windSpeed
        self.detailScale = detailScale
        self.lightingScale = lightingScale
        self.ambientScale = ambientScale
        self.time = time
        self.seed = seed
        self.quality = quality
    }

    private enum CodingKeys: CodingKey {
        case isEnabled, coverage, density, cloudType, baseAltitudeMeters, thicknessMeters, windDirection, windSpeed,
             detailScale, lightingScale, ambientScale, time, seed, quality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        coverage = try container.decodeIfPresent(Float.self, forKey: .coverage) ?? defaults.coverage
        density = try container.decodeIfPresent(Float.self, forKey: .density) ?? defaults.density
        cloudType = try container.decodeIfPresent(Float.self, forKey: .cloudType) ?? defaults.cloudType
        baseAltitudeMeters = try container.decodeIfPresent(Float.self, forKey: .baseAltitudeMeters) ?? defaults.baseAltitudeMeters
        thicknessMeters = try container.decodeIfPresent(Float.self, forKey: .thicknessMeters) ?? defaults.thicknessMeters
        windDirection = try container.decodeIfPresent(Vector2.self, forKey: .windDirection) ?? defaults.windDirection
        windSpeed = try container.decodeIfPresent(Float.self, forKey: .windSpeed) ?? defaults.windSpeed
        detailScale = try container.decodeIfPresent(Float.self, forKey: .detailScale) ?? defaults.detailScale
        lightingScale = try container.decodeIfPresent(Float.self, forKey: .lightingScale) ?? defaults.lightingScale
        ambientScale = try container.decodeIfPresent(Float.self, forKey: .ambientScale) ?? defaults.ambientScale
        time = try container.decodeIfPresent(Float.self, forKey: .time)
        seed = try container.decodeIfPresent(UInt32.self, forKey: .seed) ?? defaults.seed
        quality = try container.decodeIfPresent(CloudQuality3D.self, forKey: .quality) ?? defaults.quality
    }

    /// Whether the layer can change the image. A camera that returns `false` pays nothing for it.
    var changesImage: Bool {
        isEnabled
            && finiteRenderValue(coverage, fallback: Self().coverage, range: 0...1) > 0
            && finiteRenderValue(density, fallback: Self().density, range: 0...16) > 0
    }

    /// Settings clamped to ranges the shaders handle, replacing non-finite values with defaults.
    var sanitized: Self {
        let defaults = Self()
        var direction = windDirection
        if !direction.x.isFinite || !direction.y.isFinite || direction.x * direction.x + direction.y * direction.y < 1e-12 {
            direction = defaults.windDirection
        } else {
            let length = (direction.x * direction.x + direction.y * direction.y).squareRoot()
            direction = Vector2(direction.x / length, direction.y / length)
        }
        return Self(
            isEnabled: isEnabled,
            coverage: finiteRenderValue(coverage, fallback: defaults.coverage, range: 0...1),
            density: finiteRenderValue(density, fallback: defaults.density, range: 0...16),
            cloudType: finiteRenderValue(cloudType, fallback: defaults.cloudType, range: 0...1),
            baseAltitudeMeters: finiteRenderValue(baseAltitudeMeters, fallback: defaults.baseAltitudeMeters, range: 0...20_000),
            thicknessMeters: finiteRenderValue(thicknessMeters, fallback: defaults.thicknessMeters, range: 100...20_000),
            windDirection: direction,
            windSpeed: finiteRenderValue(windSpeed, fallback: defaults.windSpeed, range: 0...100),
            detailScale: finiteRenderValue(detailScale, fallback: defaults.detailScale, range: 0.1...8),
            lightingScale: finiteRenderValue(lightingScale, fallback: defaults.lightingScale, range: 0...10),
            ambientScale: finiteRenderValue(ambientScale, fallback: defaults.ambientScale, range: 0...10),
            time: time.flatMap { $0.isFinite ? $0 : nil },
            seed: seed,
            quality: quality
        )
    }
}
