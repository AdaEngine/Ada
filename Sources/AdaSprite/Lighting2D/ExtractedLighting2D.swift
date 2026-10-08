//
//  ExtractedLighting2D.swift
//  AdaEngine
//

import AdaECS
import AdaRender
import AdaTransform
import AdaUtils
import Math

/// Extracted point or directional light for the render world.
public struct ExtractedLight2DInstance: Sendable {
    public var worldPosition: Vector2
    public var kind: Light2DKind
    public var color: Color
    public var energy: Float
    public var direction: Vector2
    public var radius: Float
    public var spotAngle: Float
    public var texture: Texture2D?
    public var castsShadows: Bool
}

/// World-space occluder ring (CCW).
public struct ExtractedOccluder2DInstance: Sendable {
    public var worldPointsCCW: [Vector2]
    public var isEnabled: Bool

    public init(worldPointsCCW: [Vector2], isEnabled: Bool = true) {
        self.worldPointsCCW = worldPointsCCW
        self.isEnabled = isEnabled
    }
}

/// Data extracted from the main world for 2D lighting each frame.
public struct ExtractedLighting2D: Resource, Sendable {
    public var modulate: Color
    public var lights: [ExtractedLight2DInstance]
    public var occluders: [ExtractedOccluder2DInstance]

    public init(
        modulate: Color = .white,
        lights: [ExtractedLight2DInstance] = [],
        occluders: [ExtractedOccluder2DInstance] = []
    ) {
        self.modulate = modulate
        self.lights = lights
        self.occluders = occluders
    }

    /// When true, ``Main2DRenderNode`` renders albedo to ``RenderViewTarget/sceneColorTexture`` and ``Light2DCompositeRenderNode`` composites to ``mainTexture``.
    public var requiresDeferredPipeline: Bool {
        let m = modulate
        let modulateIsNonTrivial =
            abs(m.red - 1) > 0.001
            || abs(m.green - 1) > 0.001
            || abs(m.blue - 1) > 0.001
            || abs(m.alpha - 1) > 0.001
        return !lights.isEmpty || modulateIsNonTrivial
    }
}
