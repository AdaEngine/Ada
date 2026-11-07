import AdaAssets
import AdaECS
import AdaGeometry
@_spi(Internal) import AdaRender
import Foundation
import Math

/// The committed mesh document and opt-in queries for its rendered generation.
/// No heightfield approximation is exposed for editing or placement.
public struct MeshTerrain3DSourceSurface: Component, Sendable {
    public let asset: MeshTerrainDocumentAsset
    public let queries: TerrainSurfaceQueries?
    public let sections: [UUID: TerrainTileCoordinate]
}

/// Palette and prototype references published with the accepted mesh surface.
public struct MeshTerrain3DSourceResources: Component, Sendable {
    public let manifest: TerrainManifestAsset
}

struct MeshTerrainPreparedPrototype: Sendable {
    let reference: TerrainMeshPrototypeReference
    let prototype: TerrainMeshPrototype
}

struct MeshTerrainInstanceCellInput: Equatable, Sendable {
    let prototypeGeneration: UUID
    let placements: [MeshTerrainPlacement]
}

enum MeshTerrainSourcePreparation {
    static func prepare(cache: TerrainRegionCache, source: Terrain3DSource, request: TerrainSourceRequest, assetOverride: MeshTerrainDocumentAsset? = nil) async throws -> TerrainSourceBuild {
        let manifest = cache.manifest
        guard let name = manifest.meshDocumentFileName else { throw TerrainSourceError.invalidConfiguration }
        let asset: MeshTerrainDocumentAsset
        if let assetOverride { asset = assetOverride }
        else { asset = try await AssetsManager.loadFresh(MeshTerrainDocumentAsset.self, at: TerrainRegionCache.resourcePath(name, manifestPath: source.source)) }
        let compiled = try asset.acceptedCompiledProduct()
        let storage = try TerrainHeightStorage(spacing: manifest.spacing, origin: [manifest.originX, manifest.originZ], memoryBudgetBytes: 0)
        var coordinates: [TerrainTileCoordinate] = [], changed: [TerrainTileCoordinate: TerrainSourcePreparedTile] = [:]
        var selections: [TerrainTileCoordinate: TerrainLODSelection] = [:]
        var remaining = source.maximumMeshBytes
        var materialPreparation = try manifest.materials.map { try MeshTerrainMaterialPreparation(palette: $0, document: asset.document) }
        if materialPreparation == nil, !asset.document.paint.isEmpty || asset.document.modifiers.contains(where: { $0.enabled && $0.materialLayer != nil }) {
            throw TerrainSourceError.resourceLoadingFailed("Mesh Terrain refers to a material layer but has no material palette.")
        }
        let sourceStyles = MeshTerrainPreparedSourceDraws.styles(asset.document)
        let modelPaths = Set(sourceStyles.values.flatMap { $0.appearance.parts.compactMap { $0.material.modelMaterial?.path } })
        let sourceMaterialModels = try await cache.loadMeshTerrainMaterialModels(modelPaths, maximumBytes: remaining)
        remaining -= sourceMaterialModels.bytes
        let oldSourceStyles = request.meshAsset.map { MeshTerrainPreparedSourceDraws.styles($0.document) } ?? [:]
        var canonicalChanged: Set<TerrainTileCoordinate> = []
        var materialEvaluations = 0
        var queries = try TerrainSourceQueryPreparation(settings: source.queries)
        var geometryKey = Data("AdaMeshTerrain.queries.v1".utf8)
        let canReuse = request.loadedKey == TerrainSourceKey(source)
        for (index, patch) in compiled.patches.enumerated() where !patch.surface.indices.isEmpty {
            try Task.checkCancellation()
            let surface = patch.surface
            let bytes = surface.positions.count * 128 + surface.indices.count * 8
                + (materialPreparation == nil ? 0 : MeshTerrainMaterialPreparation.charge(for: surface))
            guard bytes <= remaining else { throw TerrainSourceError.meshBudgetExceeded }
            remaining -= bytes
            let coordinate = TerrainTileCoordinate(x: index, z: 0)
            var descriptor = MeshDescriptor(name: "Mesh Terrain Section \(patch.id)")
            descriptor.positions = .init(surface.positions)
            descriptor.normals = .init(normals(surface))
            if !surface.textureCoordinates.isEmpty { descriptor.textureCoordinates = .init(surface.textureCoordinates) }
            descriptor.indicies = surface.indices
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let key = MeshTerrainContentKey.digest(try encoder.encode(surface))
            geometryKey.append(contentsOf: patch.id.uuidString.utf8)
            geometryKey.append(key)
            let revision = key.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let same = canReuse && request.revisions[coordinate] == revision
            let query = try queries.prepare(descriptor, previous: request.queryIndices[coordinate], sameGeometry: same)
            let display: MeshDescriptor
            let enableLOD = source.maximumLOD > 0
            if let prepared = try materialPreparation?.prepare(surface, paint: patch.paint, canonical: &descriptor, maximumScratchBytes: remaining,
                sharesUniformVertices: enableLOD && surface.indices.count <= 73_728) {
                display = prepared
                materialEvaluations += surface.indices.count
            } else { display = descriptor }
            let previous = request.canonicalDescriptors[coordinate]
            let sameFields = same && request.meshMaterials?.palette == manifest.materials
                && descriptor[TerrainSourceMaterials.layerIDs]?.elements == previous?[TerrainSourceMaterials.layerIDs]?.elements
                && descriptor[TerrainSourceMaterials.weights]?.elements == previous?[TerrainSourceMaterials.weights]?.elements
            if !sameFields { canonicalChanged.insert(coordinate) }
            var sourceDraws = try MeshTerrainPreparedSourceDraws.build(styles: sourceStyles, surface: surface, canonical: descriptor,
                terrainDisplay: display, paint: patch.paint, models: sourceMaterialModels.models, remaining: &remaining)
            var sameLayout = sameFields && sourceStyles == oldSourceStyles && enableLOD == ((request.residentSettings?.maximumLOD ?? 0) > 0)
            var draw = sourceDraws?.terrain ?? display
            if enableLOD {
                let previousLOD = request.displayDescriptors[coordinate]?.meshletLOD
                let charge = MeshTerrainMeshletLOD.bytes(for: previousLOD)
                if sameLayout, charge <= remaining {
                    draw.meshletLOD = previousLOD
                    remaining -= charge
                } else {
                    sameLayout = false
                    remaining -= try MeshTerrainMeshletLOD.prepare(&draw, maximumBytes: remaining)
                }
            }
            if let parts = sourceDraws?.parts { sourceDraws = .init(terrain: draw, parts: parts) }
            changed[coordinate] = .init(canonical: descriptor, display: draw, revision: revision,
                reusesMesh: sameLayout, reusesCollision: same, query: query, sourceDraws: sourceDraws)
            coordinates.append(coordinate); selections[coordinate] = .init(level: 0, finerEdges: [])
        }
        var build = TerrainSourceBuild(storage: storage, revision: storage.revision, coordinates: coordinates, changed: changed,
                                       canonicalChanged: canonicalChanged, selections: selections, target: nil, expectedTargetRevision: nil, residency: nil)
        build.meshAsset = asset
        build.meshManifest = manifest
        build.meshEvaluator = request.meshEvaluator ?? .init()
        // The empty height storage only participates in the shared job protocol.
        // Query consumers need a revision of the actual section geometry instead.
        build.meshQueryRevision = MeshTerrainContentKey.digest(geometryKey).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        if let palette = manifest.materials {
            let maps: TerrainPreparedMaterialMaps
            if canReuse, let old = request.meshMaterials, old.palette == palette { maps = old.maps }
            else { maps = try await TerrainPreparedMaterialMaps.prepare(palette: palette, cache: cache, maximumBytes: remaining) }
            guard maps.chargedBytes <= remaining else { throw TerrainSourceError.meshBudgetExceeded }
            remaining -= maps.chargedBytes
            build.meshMaterials = .init(palette: palette, maps: maps)
            build.materialSampleEvaluationCount = materialEvaluations
        }
        let population = try await instances(compiled.placements, rules: asset.populationRules, cache: cache, previousCells: canReuse ? request.instanceCells : [:],
            previousPrototypes: canReuse ? request.meshPrototypes : [:], maximumBytes: remaining)
        build.instanceCells = population.cells
        build.meshPrototypes = population.prototypes
        build.groupedInstanceRecordCount = compiled.placements.count
        return build
    }

    private static func normals(_ surface: TriangleSurface) -> [Vector3] {
        if !surface.normals.isEmpty { return surface.normals }
        var result = [Vector3](repeating: .zero, count: surface.positions.count)
        for start in stride(from: 0, to: surface.indices.count, by: 3) {
            let a = Int(surface.indices[start]), b = Int(surface.indices[start + 1]), c = Int(surface.indices[start + 2])
            let normal = (surface.positions[b] - surface.positions[a]).cross(surface.positions[c] - surface.positions[a])
            result[a] += normal; result[b] += normal; result[c] += normal
        }
        return result.map { $0.squaredLength > 0 ? $0.normalized : .up }
    }

    private static func instances(_ placements: [MeshTerrainPlacement], rules: [MeshTerrainPopulationRule], cache: TerrainRegionCache,
                                  previousCells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell],
                                  previousPrototypes: [UInt16: MeshTerrainPreparedPrototype], maximumBytes: Int) async throws
        -> (cells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell], prototypes: [UInt16: MeshTerrainPreparedPrototype]) {
        let manifest = cache.manifest
        let references = Dictionary(uniqueKeysWithValues: manifest.meshPrototypes.map { ($0.id, $0) })
        let cellScales = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.cellSize) })
        let temporaryBytesPerRecord = MemoryLayout<MeshTerrainPlacement>.stride + 160
        guard placements.count <= maximumBytes / temporaryBytesPerRecord else { throw TerrainSourceError.meshBudgetExceeded }
        var groups: [TerrainInstanceCellKey: [MeshTerrainPlacement]] = [:]
        for (index, placement) in placements.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let scale = placement.ruleID.flatMap { cellScales[$0] } ?? 16
            let origin = placement.transform.origin
            // Check on every platform before conversion; a finite Float may exceed a portable cell index.
            func band(_ value: Float) -> Int32? { Int32(exactly: floor(Double(value) / Double(scale))) }
            guard let x = band(origin.x), let y = band(origin.y), let z = band(origin.z) else { throw TriangleGeometryError.invalidInput }
            let key = TerrainInstanceCellKey(coordinate: .init(x: Int(x), z: Int(z)), prototype: placement.prototypeID,
                verticalBand: Int(y), cellScaleBits: scale.bitPattern)
            groups[key, default: []].append(placement)
        }
        var result: [TerrainInstanceCellKey: TerrainPreparedInstanceCell] = [:], prototypes: [UInt16: MeshTerrainPreparedPrototype] = [:]
        var remaining = maximumBytes - placements.count * temporaryBytesPerRecord
        for key in groups.keys.sorted() {
            try Task.checkCancellation()
            guard let reference = references[key.prototype], let records = groups[key] else { throw TriangleGeometryError.invalidInput }
            let prototype: TerrainMeshPrototype
            if let existing = prototypes[key.prototype] { prototype = existing.prototype } else {
                if let retained = previousPrototypes[key.prototype], retained.reference == reference { prototype = retained.prototype }
                else { prototype = try await cache.loadPrototype(reference) }
                guard prototype.retainedGeometryBytes <= remaining else { throw TerrainSourceError.meshBudgetExceeded }
                remaining -= prototype.retainedGeometryBytes
                prototypes[key.prototype] = .init(reference: reference, prototype: prototype)
            }
            let recordBytes = MemoryLayout<MeshTerrainPlacement>.stride
            guard records.count <= TerrainMeshPrototype.maximumPlacementsPerCell, records.count <= remaining / recordBytes else {
                throw TerrainSourceError.meshBudgetExceeded
            }
            remaining -= records.count * recordBytes
            let count = records.count * max(1, prototype.parts.count)
            guard count <= remaining / MemoryLayout<Mesh3DInstance>.stride else { throw TerrainSourceError.meshBudgetExceeded }
            let bytes = count * MemoryLayout<Mesh3DInstance>.stride
            remaining -= bytes
            // Compare complete retained records: a same-size batch can still
            // contain different positions or IDs after a source moves.
            let input = MeshTerrainInstanceCellInput(prototypeGeneration: prototype.collisionGeometryID, placements: records)
            if let old = previousCells[key], old.meshInput == input {
                result[key] = old
                continue
            }
            let batches = try prototype.makeBatches(instances: records.map { .init(id: $0.id, transform: $0.transform) }, maximumExpandedBytes: bytes)
            result[key] = .init(inputID: UUID(), instanceCount: records.count, batches: batches, maximumDistance: reference.maximumDistance, meshInput: input)
        }
        return (result, prototypes)
    }
}
