import AdaECS
import AdaRender
import Math

/// Per-camera budget. Point lights consume six atlas faces; spot lights consume one.
public struct LocalShadowSettings3D: Codable, Sendable {
    public var isEnabled: Bool
    public var maximumLights: Int

    public init(isEnabled: Bool = true, maximumLights: Int = 4) {
        self.isEnabled = isEnabled
        self.maximumLights = maximumLights
    }
}

/// World-space light data copied from the scene. Range is independent of entity scale.
public struct ExtractedLocalLight3D: Sendable {
    public enum Kind: Equatable, Sendable { case point, spot }
    public var entity: Entity.ID
    public var kind: Kind
    public var position: Vector3
    public var direction: Vector3
    public var radiance: Vector3
    public var intensity: Float
    public var range: Float
    public var innerConeAngle: Float
    public var outerConeAngle: Float
    public var castsShadows: Bool
    public var shadowBias: Float
    public var shadowSlopeBias: Float
    public var shadowPriority: Int

    public init(
        entity: Entity.ID,
        kind: Kind,
        position: Vector3,
        direction: Vector3 = [0, 0, 1],
        radiance: Vector3 = .one,
        intensity: Float = 1,
        range: Float = 10,
        innerConeAngle: Float = 20,
        outerConeAngle: Float = 35,
        castsShadows: Bool = true,
        shadowBias: Float = 0.002,
        shadowSlopeBias: Float = 0.004,
        shadowPriority: Int = 0
    ) {
        self.entity = entity
        self.kind = kind
        self.position = position
        self.direction = direction
        self.radiance = radiance
        self.intensity = intensity
        self.range = range
        self.innerConeAngle = innerConeAngle
        self.outerConeAngle = outerConeAngle
        self.castsShadows = castsShadows
        self.shadowBias = shadowBias
        self.shadowSlopeBias = shadowSlopeBias
        self.shadowPriority = shadowPriority
    }
}

public enum LocalLighting3DMath {
    public static let maximumLocalLights = 32
    public static let maximumDirectionalLights = 4
    public static let maximumShadowLights = 4
    public static let shadowResolution = 512

    public static func isFinite(_ vector: Vector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    /// Smooth range cutoff multiplied by inverse-square attenuation, with a 10 cm singularity clamp.
    public static func attenuation(distance: Float, range: Float) -> Float {
        guard distance.isFinite, range.isFinite, range > 0, distance >= 0, distance < range else {
            return 0
        }
        let ratio = distance / range
        let cutoff = max(0, 1 - ratio * ratio * ratio * ratio)
        return cutoff * cutoff / max(distance * distance, 0.01)
    }

    public static func coneCosines(inner: Float, outer: Float) -> Vector2 {
        let outer = finiteRenderValue(outer, fallback: 35, range: 0.5...89)
        let inner = finiteRenderValue(inner, fallback: 20, range: 0...(outer - 0.01))
        return [Math.cos(inner * .pi / 180), Math.cos(outer * .pi / 180)]
    }

    public static func coneAttenuation(cosine: Float, inner: Float, outer: Float) -> Float {
        let cones = coneCosines(inner: inner, outer: outer)
        let value = min(max((cosine - cones.y) / max(cones.x - cones.y, 0.00001), 0), 1)
        return value * value * (3 - 2 * value)
    }

    static func influence(_ light: ExtractedLocalLight3D, cameraPosition: Vector3) -> Float {
        light.intensity / max((light.position - cameraPosition).squaredLength, 1)
    }

    public static func select(_ lights: [ExtractedLocalLight3D], viewProjection: Transform3D, cameraPosition: Vector3) -> [ExtractedLocalLight3D] {
        var visible = lights.filter { light in
            light.intensity.isFinite && light.intensity > 0 && light.range.isFinite && light.range > 0
                && isFinite(light.position) && isFinite(light.radiance)
                && (light.kind == .point || (isFinite(light.direction) && light.direction.squaredLength > 0.000001))
                && MeshVisibility3DMath.intersects(AABB(center: light.position, halfExtents: Vector3.one * light.range), viewProjection: viewProjection)
        }
        visible.sort {
            let a = influence($0, cameraPosition: cameraPosition)
            let b = influence($1, cameraPosition: cameraPosition)
            return a == b ? $0.entity < $1.entity : a > b
        }
        if visible.count > maximumLocalLights { visible.removeLast(visible.count - maximumLocalLights) }
        return visible
    }

    /// Left-handed +Z view; choose a nonparallel up vector for vertical lights and cube faces.
    public static func view(position: Vector3, direction: Vector3) -> Transform3D {
        let forward = direction.normalized
        let up: Vector3 = abs(forward.dot(.up)) > 0.95 ? .right : .up
        let right = up.cross(forward).normalized
        let vertical = forward.cross(right)
        return Transform3D(
            [right.x, vertical.x, forward.x, 0],
            [right.y, vertical.y, forward.y, 0],
            [right.z, vertical.z, forward.z, 0],
            [-right.dot(position), -vertical.dot(position), -forward.dot(position), 1]
        )
    }

    /// Matches the shader's dominant-axis cube-face selection (+X,-X,+Y,-Y,+Z,-Z).
    public static func pointFace(direction: Vector3) -> Int {
        let x = abs(direction.x)
        let y = abs(direction.y)
        let z = abs(direction.z)
        if x >= y && x >= z {
            return direction.x >= 0 ? 0 : 1
        }
        if y >= z {
            return direction.y >= 0 ? 2 : 3
        }
        return direction.z >= 0 ? 4 : 5
    }

    public static func shadowProjections(_ light: ExtractedLocalLight3D) -> [Transform3D] {
        let range = finiteRenderValue(light.range, fallback: 10, range: 0.1...500)
        let near = min(0.05, range * 0.05)
        let outer = finiteRenderValue(light.outerConeAngle, fallback: 35, range: 0.5...89)
        let projection = Transform3D.perspective(fieldOfView: .degrees(light.kind == .point ? 90 : outer * 2), aspectRatio: 1, zNear: near, zFar: range)
        let directions: [Vector3] = light.kind == .point ? [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]] : [light.direction]
        return directions.map { projection * view(position: light.position, direction: $0) }
    }
}

/// Stable slots within a camera's bounded atlas. Changing rank doesn't move retained winners.
public struct LocalShadow3DAllocator: Sendable {
    public private(set) var slots: [Entity.ID: Int] = [:]
    public init() {}

    public mutating func select(_ lights: [ExtractedLocalLight3D], cameraPosition: Vector3, budget: Int) {
        let budget = min(max(budget, 0), LocalLighting3DMath.maximumShadowLights)
        let winners = lights.filter(\.castsShadows).sorted {
            if $0.shadowPriority != $1.shadowPriority {
                return $0.shadowPriority > $1.shadowPriority
            }
            let a = LocalLighting3DMath.influence($0, cameraPosition: cameraPosition)
            let b = LocalLighting3DMath.influence($1, cameraPosition: cameraPosition)
            return a == b ? $0.entity < $1.entity : a > b
        }.prefix(budget)
        let ids = Set(winners.map(\.entity))
        for (id, slot) in slots where !ids.contains(id) || slot >= budget { slots.removeValue(forKey: id) }
        for light in winners where slots[light.entity] == nil {
            if let free = (0..<budget).first(where: { !slots.values.contains($0) }) { slots[light.entity] = free }
        }
    }
}

/// Frame-buffered packed vec4 arrays have the exact GLSL std140 layout, without Swift Array headers in GPU data.
struct LocalLighting3DGPUScratch: Resource {
    private struct Key: Hashable {
        var view: Entity.ID
        var pass: Int
    }
    private struct Entry {
        var buffers: [BufferData<Vector4>]
        var index = 0
    }
    private var entries: [Key: Entry] = [:]
    private let frames = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)

    mutating func retainViews(_ views: [Entity.ID]) {
        for key in entries.keys where !views.contains(key.view) { entries.removeValue(forKey: key) }
    }

    mutating func write(view: Entity.ID, pass: Int = 0, count: Int, device: RenderDevice, fill: (inout [Vector4]) -> Void) -> BufferData<Vector4> {
        let key = Key(view: view, pass: pass)
        var entry = entries.removeValue(forKey: key) ?? Entry(buffers: (0..<frames).map { _ in BufferData(elements: [Vector4](repeating: .zero, count: count)) })
        entry.index = (entry.index + 1) % frames
        fill(&entry.buffers[entry.index].elements)
        entry.buffers[entry.index].write(to: device)
        let output = entry.buffers[entry.index]
        entries[key] = entry
        return output
    }
}

struct LocalShadow3DViews: Resource {
    struct Entry {
        var lights: [ExtractedLocalLight3D] = []
        var allocator = LocalShadow3DAllocator()
        var color: RenderTexture?
        var depth: RenderTexture?
        var matrices = [Transform3D](repeating: .identity, count: 24)
    }
    var entries: [Entity.ID: Entry] = [:]
}

func packLocalLighting(_ lighting: ExtractedLighting3D, view: Transform3D, shadows: LocalShadow3DViews.Entry?, into data: inout [Vector4]) {
    let additional = lighting.directionalLights.dropFirst().prefix(3)
    let lights = shadows?.lights ?? []
    data[0] = [Float(additional.count), Float(lights.count), 0, 0]
    for (index, light) in additional.enumerated() {
        data[1 + index] = Vector4((view * Vector4(light.directionToLight, 0)).xyz.normalized, light.intensity)
        data[4 + index] = Vector4(light.radiance, 0)
    }
    for (index, light) in lights.enumerated() {
        let cones = LocalLighting3DMath.coneCosines(inner: light.innerConeAngle, outer: light.outerConeAngle)
        let slot = shadows?.allocator.slots[light.entity]
        let offset = 7 + index * 4
        data[offset] = Vector4((view * Vector4(light.position, 1)).xyz, light.range)
        data[offset + 1] = Vector4(light.radiance, light.intensity)
        data[offset + 2] = Vector4((view * Vector4(light.direction, 0)).xyz.normalized, light.kind == .point ? -1 : cones.y)
        data[offset + 3] = [
            cones.x, finiteRenderValue(light.shadowBias, fallback: 0.002, range: 0...0.05), finiteRenderValue(light.shadowSlopeBias, fallback: 0.004, range: 0...0.05),
            slot.map(Float.init) ?? -1,
        ]
    }
}

func packLocalShadowMatrices(_ shadows: LocalShadow3DViews.Entry?, into data: inout [Vector4]) {
    for index in 0..<24 {
        let matrix = shadows?.matrices[index] ?? .identity
        data[index * 4] = matrix.x
        data[index * 4 + 1] = matrix.y
        data[index * 4 + 2] = matrix.z
        data[index * 4 + 3] = matrix.w
    }
    data[96] = [1 / Float(shadows?.color?.size.width ?? 1), 1 / Float(shadows?.color?.size.height ?? 1), Float(LocalLighting3DMath.shadowResolution), 0]
}
