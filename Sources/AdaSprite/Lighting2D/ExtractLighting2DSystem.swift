//
//  ExtractLighting2DSystem.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
import AdaRender
import AdaTransform
import AdaUtils
import Math

@System
@inline(__always)
public func ExtractLighting2D(
    _ lights: Extract<Query<Entity, Light2D, GlobalTransform, Visibility>>,
    _ modulateQuery: Extract<Query<Entity, LightModulate2D>>,
    _ occluders: Extract<Query<Entity, LightOccluder2D, GlobalTransform, Visibility>>,
    _ extracted: ResMut<ExtractedLighting2D>
) {
    extracted.lights.removeAll(keepingCapacity: true)
    extracted.occluders.removeAll(keepingCapacity: true)
    extracted.modulate = .white

    modulateQuery.wrappedValue.forEach { _, mod in
        extracted.modulate = mod.color
    }

    lights.wrappedValue.forEach { _, light, globalTransform, visibility in
        guard light.isEnabled, visibility != .hidden else {
            return
        }
        let matrix = globalTransform.matrix
        let origin = matrix.origin
        let worldPosition = Vector2(origin.x, origin.y)
        let tex: Texture2D?
        if let handle = light.texture {
            tex = handle.asset
        } else {
            tex = nil
        }
        extracted.lights.append(
            ExtractedLight2DInstance(
                worldPosition: worldPosition,
                kind: light.kind,
                color: light.color,
                energy: light.energy,
                direction: light.direction,
                radius: light.radius,
                spotAngle: light.spotAngle,
                texture: tex,
                castsShadows: light.castsShadows
            )
        )
    }

    occluders.wrappedValue.forEach { _, occluder, globalTransform, visibility in
        guard occluder.isEnabled, visibility != .hidden, occluder.points.count >= 3 else {
            return
        }
        let matrix = globalTransform.matrix
        var ring: [Vector2] = []
        ring.reserveCapacity(occluder.points.count)
        for point in occluder.points {
            let transformed = matrix * Vector4(point.x, point.y, 0, 1)
            ring.append(Vector2(transformed.x, transformed.y))
        }
        // A reflected tile or parent reverses winding. Shadow-fin edge tests require world-space CCW.
        // Triangulate relative to one point to avoid cancellation from large world translations.
        var signedArea: Float = 0
        for index in 1..<(ring.count - 1) {
            let first = ring[index] - ring[0]
            let second = ring[index + 1] - ring[0]
            signedArea += first.x * second.y - first.y * second.x
        }
        if signedArea < 0 {
            ring.reverse()
        }
        extracted.occluders.append(ExtractedOccluder2DInstance(worldPointsCCW: ring, isEnabled: true))
    }
}
