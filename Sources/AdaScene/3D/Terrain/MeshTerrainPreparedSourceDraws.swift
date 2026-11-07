import AdaGeometry
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// The canonical tile remains one indexed surface for queries and collision. Only
/// drawing is split: retained opaque source triangles use their original UVs.
struct MeshTerrainPreparedSourceDraws: Sendable {
    struct Part: Sendable {
        let descriptor: MeshDescriptor
        let material: PBRMaterial
    }

    struct Style: Equatable, Sendable {
        let appearance: MeshTerrainSourceAppearance
        let original: TriangleSurface
        let transform: Transform3D
    }

    private struct Key: Hashable, Comparable {
        let source: UInt32
        let group: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.source == rhs.source ? lhs.group < rhs.group : lhs.source < rhs.source
        }
    }

    let terrain: MeshDescriptor
    let parts: [Part]

    static func styles(_ document: MeshTerrainDocument) -> [UInt32: Style] {
        var styles: [UInt32: Style] = [:]
        for modifier in document.modifiers where modifier.enabled && modifier.operation == .union && modifier.materialLayer == nil {
            if let appearance = modifier.sourceAppearance {
                styles[modifier.sourceID] = .init(appearance: appearance, original: modifier.surface, transform: modifier.transform)
            }
        }
        return styles
    }

    static func build(
        styles: [UInt32: Style], surface: TriangleSurface, canonical: MeshDescriptor,
        terrainDisplay: MeshDescriptor, paint: MeshTerrainCompiledPaint?, models: [String: [Material]], remaining: inout Int
    ) throws -> Self? {
        guard !styles.isEmpty, !surface.faceSources.isEmpty, !surface.faceIDs.isEmpty,
            let normals = canonical.normals?.elements else { return nil }
        let paintedFaces = Set((paint?.samples ?? []).map { $0.corner / 3 })
        var groups: [Key: [Int]] = [:]
        var terrain = terrainDisplay
        terrain.indicies = []
        for face in surface.faceSources.indices {
            if face.isMultiple(of: 128) { try Task.checkCancellation() }
            let source = surface.faceSources[face]
            if !paintedFaces.contains(face), let group = styles[source]?.appearance.group(for: surface.faceIDs[face]) {
                guard remaining >= 320 else { throw TerrainSourceError.meshBudgetExceeded }
                remaining -= 320
                groups[Key(source: source, group: group), default: []].append(face)
            } else {
                let start = face * 3
                terrain.indicies.append(contentsOf: terrainDisplay.indicies[start..<(start + 3)])
            }
        }
        guard !groups.isEmpty else { return nil }
        guard groups.count <= 512 else { throw TerrainSourceError.meshBudgetExceeded }
        let parts = try groups.keys.sorted().map { key -> Part in
            guard let faces = groups[key], let style = styles[key.source] else { throw TerrainSourceError.changedDuringBuild }
            let display = try descriptor(for: key, faces: faces, surface: surface, normals: normals, style: style)
            let material = try material(for: style.appearance.parts[key.group].material, models: models)
            return .init(descriptor: display, material: material)
        }
        return .init(terrain: terrain, parts: parts)
    }

    private static func descriptor(
        for key: Key, faces: [Int], surface: TriangleSurface, normals: [Vector3], style: Style
    ) throws -> MeshDescriptor {
        var positions: [Vector3] = [], shadingNormals: [Vector3] = [], uv: [Vector2] = [], secondaryUV: [Vector2] = [], colors: [Color] = []
        let count = faces.count * 3
        positions.reserveCapacity(count); shadingNormals.reserveCapacity(count); uv.reserveCapacity(count)
        let uv1 = style.appearance.secondaryUV, sourceColors = style.appearance.vertexColors
        if uv1 != nil { secondaryUV.reserveCapacity(count) }
        if sourceColors != nil { colors.reserveCapacity(count) }
        let inverse = style.transform.inverse
        for face in faces {
            if face.isMultiple(of: 128) { try Task.checkCancellation() }
            let originalFace = Int(surface.faceIDs[face]) * 3
            let a = Int(style.original.indices[originalFace]), b = Int(style.original.indices[originalFace + 1]), c = Int(style.original.indices[originalFace + 2])
            let projection = uv1 != nil || sourceColors != nil ? Barycentric(
                style.original.positions[a], style.original.positions[b], style.original.positions[c]
            ) : nil
            for corner in 0..<3 {
                let vertex = Int(surface.indices[face * 3 + corner])
                let point = surface.positions[vertex]
                positions.append(point); shadingNormals.append(normals[vertex])
                uv.append(surface.textureCoordinates.isEmpty ? .zero : surface.textureCoordinates[vertex])
                if let projection {
                    let local = (inverse * Vector4(point, 1)).xyz
                    let w = projection.weights(local)
                    if let uv1 { secondaryUV.append(uv1[a] * w.x + uv1[b] * w.y + uv1[c] * w.z) }
                    if let sourceColors { colors.append(Color(sourceColors[a] * w.x + sourceColors[b] * w.y + sourceColors[c] * w.z)) }
                }
            }
        }
        var display = MeshDescriptor(name: "Joined source \(key.source), part \(key.group)")
        display.positions = .init(positions); display.normals = .init(shadingNormals)
        display.textureCoordinates = .init(uv)
        if !secondaryUV.isEmpty { display[MeshDescriptor.textureCoordinates1] = .init(secondaryUV) }
        if !colors.isEmpty { display.colors = .init(colors) }
        display.indicies = positions.indices.map(UInt32.init)
        return display
    }

    private struct Barycentric {
        let a: SIMD3<Double>
        let e1: SIMD3<Double>
        let e2: SIMD3<Double>
        let d11: Double
        let d12: Double
        let d22: Double
        let denominator: Double

        init(_ a: Vector3, _ b: Vector3, _ c: Vector3) {
            self.a = Self.precise(a)
            e1 = Self.precise(b) - self.a
            e2 = Self.precise(c) - self.a
            d11 = Self.dot(e1, e1); d12 = Self.dot(e1, e2); d22 = Self.dot(e2, e2)
            denominator = d11 * d22 - d12 * d12
        }

        func weights(_ point: Vector3) -> Vector3 {
            guard denominator.isFinite, denominator > 0 else { return [1, 0, 0] }
            let p = Self.precise(point) - a
            let a1 = Self.dot(p, e1), a2 = Self.dot(p, e2)
            let v = (d22 * a1 - d12 * a2) / denominator, w = (d11 * a2 - d12 * a1) / denominator
            let clamped = Vector3(Float(max(0, 1 - v - w)), Float(max(0, v)), Float(max(0, w)))
            let sum = clamped.x + clamped.y + clamped.z
            guard sum.isFinite, sum > 0 else { return [1, 0, 0] }
            return clamped / sum
        }

        private static func precise(_ point: Vector3) -> SIMD3<Double> { .init(Double(point.x), Double(point.y), Double(point.z)) }
        private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    }

    private static func material(for style: MeshTerrainSourceAppearance.Material, models: [String: [Material]]) throws -> PBRMaterial {
        if let reference = style.modelMaterial {
            guard let materials = models[reference.path], materials.indices.contains(reference.index),
                let original = materials[reference.index] as? PBRMaterial, original.effectiveAlphaMode == .opaque,
                original.baseColorFactor == style.baseColor, original.roughnessFactor == style.roughness, original.metallicFactor == style.metallic,
                original.emissiveFactor == style.emission, original.emissiveStrength == style.emissionStrength, original.doubleSided == style.doubleSided
            else { throw TerrainSourceError.resourceLoadingFailed("Joined source material changed. Rejoin the original model to refresh the terrain.") }
            return original
        }
        let material = PBRMaterial()
        material.baseColorFactor = style.baseColor
        material.roughnessFactor = style.roughness
        material.metallicFactor = style.metallic
        material.emissiveFactor = style.emission
        material.emissiveStrength = style.emissionStrength
        material.doubleSided = style.doubleSided
        return material
    }

    func mesh(using device: RenderDevice) -> Mesh {
        let hasTerrain = !terrain.indicies.isEmpty
        let descriptors = (hasTerrain ? [terrain] : []) + parts.map(\.descriptor)
        let mesh = Mesh.generate(from: descriptors, renderDevice: device)
        return Mesh(models: mesh.models.map { model in
            .init(name: model.name, parts: model.parts.enumerated().map { index, original in
                var part = original
                part.materialIndex = hasTerrain ? index : index + 1
                return part
            })
        })
    }

    func makeMaterials() -> [Material] { parts.map(\.material) }
}
