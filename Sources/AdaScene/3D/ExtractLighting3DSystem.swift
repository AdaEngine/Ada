import AdaCorePipelines
import AdaECS
import AdaRender
import AdaTransform
import Math

@System
func ExtractDirectionalLight3D(
    _ directional: Extract<Query<Entity, DirectionalLightComponent, GlobalTransform>>,
    _ points: Extract<Query<Entity, PointLightComponent, GlobalTransform>>,
    _ spots: Extract<Query<Entity, SpotLightComponent, GlobalTransform>>,
    _ visibility: Extract<Query<Entity, Visibility>>,
    _ hierarchy: Extract<Query<Entity, RelationshipComponent>>,
    _ extracted: ResMut<ExtractedLighting3D>
) {
    _ = visibility.wrappedValue
    _ = hierarchy.wrappedValue
    extracted.directionalLight = nil
    extracted.directionalLights.removeAll(keepingCapacity: true)
    extracted.localLights.removeAll(keepingCapacity: true)
    extracted.hasAuthoredLights = false
    func visible(_ entity: Entity) -> Bool {
        if entity.components[Visibility.self] == .hidden {
            return false
        }
        var ancestor = entity.parent
        while let parent = ancestor {
            if parent.components[Visibility.self] == .hidden {
                return false
            }
            ancestor = parent.parent
        }
        return true
    }
    func valid(radiance: Vector3, intensity: Float) -> Bool {
        intensity.isFinite && intensity > 0 && LocalLighting3DMath.isFinite(radiance) && max(radiance.x, max(radiance.y, radiance.z)) > 0
    }
    directional.wrappedValue.forEach { entity, light, transform in
        extracted.hasAuthoredLights = true
        let direction = transform.matrix.z.xyz
        guard visible(entity), valid(radiance: light.radiance, intensity: light.intensity),
            LocalLighting3DMath.isFinite(direction), direction.squaredLength > 0.000001
        else {
            return
        }
        var value = ExtractedDirectionalLight3D(
            directionToLight: -direction.normalized,
            radiance: light.radiance,
            intensity: light.intensity,
            castsShadows: light.castShadows,
            shadowDistance: light.shadowDistance,
            shadowBias: light.shadowBias,
            shadowSlopeBias: light.shadowSlopeBias
        )
        value.entity = entity.id
        extracted.directionalLights.append(value)
    }
    // Retain a stable primary shadow-casting sun, then bounded additional directional lights.
    extracted.directionalLights.sort {
        if $0.castsShadows != $1.castsShadows {
            return $0.castsShadows
        }
        return ($0.entity ?? 0) < ($1.entity ?? 0)
    }
    if extracted.directionalLights.count > LocalLighting3DMath.maximumDirectionalLights {
        extracted.directionalLights.removeLast(extracted.directionalLights.count - LocalLighting3DMath.maximumDirectionalLights)
    }
    extracted.directionalLight = extracted.directionalLights.first
    points.wrappedValue.forEach { entity, light, transform in
        extracted.hasAuthoredLights = true
        guard visible(entity), valid(radiance: light.radiance, intensity: light.intensity), light.range.isFinite, light.range > 0 else {
            return
        }
        extracted.localLights.append(
            ExtractedLocalLight3D(
                entity: entity.id,
                kind: .point,
                position: transform.matrix.origin,
                radiance: light.radiance,
                intensity: light.intensity,
                range: min(light.range, 500),
                castsShadows: light.castShadows,
                shadowBias: light.shadowBias,
                shadowSlopeBias: light.shadowSlopeBias,
                shadowPriority: light.shadowPriority
            )
        )
    }
    spots.wrappedValue.forEach { entity, light, transform in
        extracted.hasAuthoredLights = true
        let direction = transform.matrix.z.xyz
        guard visible(entity), valid(radiance: light.radiance, intensity: light.intensity), light.range.isFinite, light.range > 0,
            LocalLighting3DMath.isFinite(direction), direction.squaredLength > 0.000001
        else {
            return
        }
        extracted.localLights.append(
            ExtractedLocalLight3D(
                entity: entity.id,
                kind: .spot,
                position: transform.matrix.origin,
                direction: direction.normalized,
                radiance: light.radiance,
                intensity: light.intensity,
                range: min(light.range, 500),
                innerConeAngle: light.innerConeAngle,
                outerConeAngle: light.outerConeAngle,
                castsShadows: light.castShadows,
                shadowBias: light.shadowBias,
                shadowSlopeBias: light.shadowSlopeBias,
                shadowPriority: light.shadowPriority
            )
        )
    }
}
