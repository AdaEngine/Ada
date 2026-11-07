import AdaECS
import AdaGeometry
@_spi(Internal) import AdaPhysics
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Math

/// A worker-safe snapshot of the chosen static triangles and their source draw ownership.
public struct MeshTerrainCapturedSource: Sendable {
    public let surface: TriangleSurface
    public let drawReplacements: [MeshTerrainDrawReplacement]
    public let appearance: MeshTerrainSourceAppearance
}

struct MeshTerrainCapturedPart: Sendable {
    let entity: Entity.ID
    let selection: MeshTerrainPartSelection
    let matrix: Transform3D
    let part: Mesh.Part
    let material: MeshTerrainSourceAppearance.Material
}

struct MeshTerrainPartGeneration: Equatable, Sendable {
    let entity: Entity.ID
    let selection: MeshTerrainPartSelection
    let matrix: Transform3D
    let vertex: ObjectIdentifier
    let index: ObjectIdentifier
    let count: Int
    let material: MeshTerrainSourceAppearance.Material
}

public enum MeshTerrainSourceCapture {
    /// Static source bodies participating in the selected hierarchy, including suspended authored bodies.
    public static func collisionSources(_ source: Entity, parts: [MeshTerrainPartSelection] = [], in world: World) throws -> [Entity.ID] {
        try MeshTerrainSourceCollisionOwnership.sources(root: source, parts: collect(source, selections: parts), world: world)
    }
    /// Captures root-local geometry. Inherited placement is retained separately on the modifier.
    public static func capture(_ source: Entity, parts: [MeshTerrainPartSelection] = [], maximumTriangles: Int = 65_536) throws -> MeshTerrainCapturedSource {
        try assemble(collect(source, selections: parts), maximumTriangles: maximumTriangles)
    }

    static func collect(_ root: Entity, selections: [MeshTerrainPartSelection]) throws -> [MeshTerrainCapturedPart] {
        guard selections.count <= 512, Set(selections).count == selections.count,
            selections.allSatisfy({ $0.nodePath.count <= 64 && $0.nodePath.allSatisfy { $0 >= 0 } && $0.model >= 0 && $0.part >= 0 }) else {
            throw TriangleGeometryError.invalidInput
        }
        var result: [MeshTerrainCapturedPart] = [], matched: Set<MeshTerrainPartSelection> = [], seen: Set<Entity.ID> = []
        var stack: [(Entity, [Int], Transform3D, String?)] = [(root, [], .identity, nil)]
        while let (entity, path, matrix, parentModel) = stack.popLast() {
            let authored = entity.components[Model3DSource.self] != nil ? portableModelPath(entity) : parentModel
            let portableModel = authored.flatMap { MeshTerrainSourceAppearance.ModelMaterial.supports($0) ? $0 : nil }
            guard seen.insert(entity.id).inserted, seen.count <= 512, path.count <= 64 else { throw TriangleGeometryError.budgetExceeded }
            if let drawable = entity.components[Mesh3DComponent.self] {
                for (modelIndex, model) in drawable.mesh.models.enumerated() { for (partIndex, part) in model.parts.enumerated() {
                    let selection = MeshTerrainPartSelection(nodePath: path, model: modelIndex, part: partIndex)
                    guard selections.isEmpty || selections.contains(selection) else { continue }
                    guard let style = materialForJoin(part, materials: drawable.materials, portableModel: portableModel) else {
                        // Cutout leaves and other unsupported draws stay authored.
                        // An explicit unsupported selection must fail rather than joining something else.
                        if !selections.isEmpty { throw TriangleGeometryError.invalidInput }
                        continue
                    }
                    guard part.primitiveTopology == .triangleList, part.morphTargets == nil,
                        entity.components[SkinnedMesh3DComponent.self] == nil, entity.components[MorphWeights3DComponent.self] == nil,
                        entity.components[PhysicsBody3DComponent.self].map({ $0.mode == .static }) ?? true,
                        root.components[PhysicsBody3DComponent.self].map({ $0.mode == .static }) ?? true,
                        part.indexCount == part.meshDescriptor.indicies.count else { throw TriangleGeometryError.invalidInput }
                    result.append(.init(entity: entity.id, selection: selection, matrix: matrix, part: part, material: style))
                    matched.insert(selection)
                } }
            }
            for (index, child) in entity.children.enumerated().reversed() {
                stack.append((child, path + [index], matrix * (child.components[Transform.self]?.matrix ?? .identity), authored))
            }
        }
        guard !result.isEmpty, selections.isEmpty || matched.count == selections.count else { throw TriangleGeometryError.invalidInput }
        return result
    }

    static func portableModelPath(_ entity: Entity) -> String? {
        guard let reference = entity.components[Model3DSource.self]?.source else { return nil }
        if reference.hasPrefix("@res://") { return reference }
        guard let hosted = entity.components[MeshTerrain3DSourceModelResource.self], hosted.resolvedPath == reference else { return nil }
        return hosted.resourcePath
    }

    private static func materialForJoin(
        _ part: Mesh.Part, materials: [Material], portableModel: String?
    ) -> MeshTerrainSourceAppearance.Material? {
        guard materials.indices.contains(part.materialIndex), let material = materials[part.materialIndex] as? PBRMaterial,
            material.effectiveAlphaMode == .opaque, material.graphMaterial == nil, material.terrainBindings == nil,
            material.lightmapTexture == nil, material.heightTexture == nil else { return nil }
        let needsModel = material.baseColorTexture != nil || material.metallicRoughnessTexture != nil || material.normalTexture != nil
            || material.occlusionTexture != nil || material.emissiveTexture != nil || !material.layerTextures.isEmpty || !material.shaderFeatures.isEmpty
            || material.ior != 1.5 || material.specularFactor != 1 || material.specularColorFactor != .one
        guard !needsModel || portableModel != nil else { return nil }
        let reference = needsModel ? portableModel.map { MeshTerrainSourceAppearance.ModelMaterial(path: $0, index: part.materialIndex) } : nil
        return .init(baseColor: material.baseColorFactor, roughness: material.roughnessFactor, metallic: material.metallicFactor,
            emission: material.emissiveFactor, emissionStrength: material.emissiveStrength, doubleSided: material.doubleSided, modelMaterial: reference)
    }

    static func generations(_ parts: [MeshTerrainCapturedPart]) -> [MeshTerrainPartGeneration] {
        parts.map { .init(entity: $0.entity, selection: $0.selection, matrix: $0.matrix,
                          vertex: ObjectIdentifier($0.part.vertexBuffer), index: ObjectIdentifier($0.part.indexBuffer), count: $0.part.indexCount,
                          material: $0.material) }
    }

    static func assemble(_ parts: [MeshTerrainCapturedPart], maximumTriangles: Int = 65_536) throws -> MeshTerrainCapturedSource {
        guard maximumTriangles > 0, maximumTriangles <= 1_048_576 else { throw TriangleGeometryError.invalidInput }
        var combined = TriangleSurface(positions: [], indices: [])
        var replacements: [Entity.ID: Set<MeshTerrainSourcePart>] = [:]
        var materials: [MeshTerrainSourceAppearance.Part] = []
        var secondaryUV: [Vector2]?, vertexColors: [Vector4]?
        for captured in parts {
            let descriptor = captured.part.meshDescriptor
            let surface = TriangleSurface(positions: descriptor.positions.elements, indices: descriptor.indicies,
                                          normals: descriptor.normals?.elements ?? [], textureCoordinates: descriptor.textureCoordinates?.elements ?? [])
            try surface.validate(maximumTriangles: maximumTriangles)
            guard surface.indices.count / 3 <= maximumTriangles - combined.indices.count / 3,
                surface.positions.count <= maximumTriangles * 3 - combined.positions.count else { throw TriangleGeometryError.budgetExceeded }
            let transformed = try surface.transformed(by: captured.matrix)
            let offset = UInt32(combined.positions.count), firstFace = UInt32(combined.indices.count / 3)
            let vertexCount = transformed.positions.count
            if let rows = descriptor[MeshDescriptor.textureCoordinates1]?.elements {
                guard rows.count == vertexCount else { throw TriangleGeometryError.invalidInput }
                if secondaryUV == nil { secondaryUV = Array(repeating: .zero, count: Int(offset)) }
                secondaryUV?.append(contentsOf: rows)
            } else if secondaryUV != nil { secondaryUV?.append(contentsOf: repeatElement(.zero, count: vertexCount)) }
            if let rows = descriptor.colors?.elements {
                guard rows.count == vertexCount else { throw TriangleGeometryError.invalidInput }
                if vertexColors == nil { vertexColors = Array(repeating: .one, count: Int(offset)) }
                vertexColors?.append(contentsOf: rows.map { [$0.red, $0.green, $0.blue, $0.alpha] })
            } else if vertexColors != nil { vertexColors?.append(contentsOf: repeatElement(.one, count: vertexCount)) }
            combined.positions += transformed.positions
            combined.indices += transformed.indices.map { $0 + offset }
            combined.normals += transformed.normals.isEmpty ? normals(transformed) : transformed.normals
            combined.textureCoordinates += transformed.textureCoordinates.isEmpty ? Array(repeating: .zero, count: transformed.positions.count) : transformed.textureCoordinates
            let faceCount = UInt32(transformed.indices.count / 3)
            combined.faceIDs += (0..<faceCount).map { $0 + firstFace }
            if faceCount > 0 { materials.append(.init(firstFace: firstFace, faceCount: faceCount, material: captured.material)) }
            replacements[captured.entity, default: []].insert(.init(model: captured.selection.model, part: captured.selection.part))
        }
        try combined.validate(maximumTriangles: maximumTriangles)
        let appearance = MeshTerrainSourceAppearance(parts: materials, secondaryUV: secondaryUV, vertexColors: vertexColors)
        try appearance.validate(faceCount: combined.indices.count / 3, vertexCount: combined.positions.count)
        return .init(surface: combined, drawReplacements: replacements.keys.sorted().map { .init(entity: $0, parts: replacements[$0] ?? []) },
                     appearance: appearance)
    }

    private static func normals(_ surface: TriangleSurface) -> [Vector3] {
        var result = Array(repeating: Vector3.zero, count: surface.positions.count)
        for start in stride(from: 0, to: surface.indices.count, by: 3) {
            let a = Int(surface.indices[start]), b = Int(surface.indices[start + 1]), c = Int(surface.indices[start + 2])
            let normal = (surface.positions[b] - surface.positions[a]).cross(surface.positions[c] - surface.positions[a])
            result[a] += normal; result[b] += normal; result[c] += normal
        }
        return result.map { $0.squaredLength > 0 ? $0.normalized : .up }
    }
}
