import Math

/// One compact lighting packet per view, shared by every smoke instance. No per-particle light queries.
enum ParticleLighting3D {
    static let maximumLights = 8
    static let vectorCount = 3 + maximumLights * 4 + 4

    static func pack(_ lighting: ExtractedLighting3D, view: Transform3D, shadows: LocalShadow3DViews.Entry?, into data: inout [Vector4]) {
        let lights = (shadows?.lights ?? []).prefix(maximumLights)
        data[0] = [0.025, 0.028, 0.035, Float(lights.count)]
        let sun = lighting.directionalLight ?? ExtractedDirectionalLight3D(
            directionToLight: Vector3(0.35, 0.7, 0.45).normalized, radiance: .one,
            intensity: lighting.hasAuthoredLights ? 0 : 3.2
        )
        data[1] = Vector4((view * Vector4(sun.directionToLight, 0)).xyz, max(0, sun.intensity))
        data[2] = Vector4(sun.radiance, 0)
        for (index, light) in lights.enumerated() {
            let cones = LocalLighting3DMath.coneCosines(inner: light.innerConeAngle, outer: light.outerConeAngle)
            let slot = shadows?.color == nil ? nil : shadows?.allocator.slots[light.entity]
            let offset = 3 + index * 4
            data[offset] = Vector4((view * Vector4(light.position, 1)).xyz, light.range)
            data[offset + 1] = Vector4(light.radiance, light.intensity)
            data[offset + 2] = Vector4((view * Vector4(light.direction, 0)).xyz, light.kind == .point ? -1 : cones.y)
            data[offset + 3] = [cones.x, finiteRenderValue(light.shadowBias, fallback: 0.002, range: 0...0.05), 0, slot.map(Float.init) ?? -1]
        }
        let inverseView = view.inverse
        let offset = 3 + maximumLights * 4
        data[offset] = inverseView.x
        data[offset + 1] = inverseView.y
        data[offset + 2] = inverseView.z
        data[offset + 3] = inverseView.w
    }
}
