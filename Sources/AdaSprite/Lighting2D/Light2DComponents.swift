//
//  Light2DComponents.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

/// Kind of a ``Light2D``.
public enum Light2DKind: Codable, Sendable, Hashable {
    /// Parallel rays (e.g. sun or moon), ``Light2D/direction`` is world-space direction (XY).
    case directional
    /// Radial falloff around ``Transform`` origin; ``Light2D/radius`` in world units.
    case point
}

/// Base 2D light: point (omni / spot) or directional.
///
/// Use ``Sprite`` for textured light cookies; set ``Light2D/texture`` for a masked cookie.
@Component(
    required: [Visibility.self]
)
public struct Light2D: Codable, Sendable {
    public var kind: Light2DKind
    public var color: Color
    /// Multiplier for ``color``.
    public var energy: Float
    public var isEnabled: Bool
    /// World-space direction for ``Light2DKind/directional`` (XY; Z ignored).
    public var direction: Vector2
    /// For ``Light2DKind/point``: max reach in world units.
    public var radius: Float
    /// Optional spot half-angle in radians (0 = omnidirectional).
    public var spotAngle: Float
    /// Optional cookie texture (multiplies light).
    public var texture: AssetHandle<Texture2D>?
    /// When true, ``LightOccluder2D`` geometry can shadow this light.
    public var castsShadows: Bool

    public init(
        kind: Light2DKind = .point,
        color: Color = .white,
        energy: Float = 1,
        isEnabled: Bool = true,
        direction: Vector2 = Vector2(0, -1),
        radius: Float = 400,
        spotAngle: Float = 0,
        texture: AssetHandle<Texture2D>? = nil,
        castsShadows: Bool = true
    ) {
        self.kind = kind
        self.color = color
        self.energy = energy
        self.isEnabled = isEnabled
        self.direction = direction
        self.radius = radius
        self.spotAngle = spotAngle
        self.texture = texture
        self.castsShadows = castsShadows
    }
}

/// Closed polygon in **local** space used to build 2D shadow volumes.
@Component(
    required: [Visibility.self]
)
public struct LightOccluder2D: Codable, Sendable {
    public var points: [Vector2]
    public var isEnabled: Bool

    public init(points: [Vector2] = [], isEnabled: Bool = true) {
        self.points = points
        self.isEnabled = isEnabled
    }
}

/// Ambient-style multiplier for regions not reached by lights (Godot ``CanvasModulate``-style).
///
/// Attach to the same entity as ``Camera`` (or any entity picked first by the extractor).
@Component
public struct LightModulate2D: Codable, Sendable {
    public var color: Color

    public init(color: Color = .white) {
        self.color = color
    }
}
