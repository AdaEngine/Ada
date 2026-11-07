import Foundation
import Math

extension MeshTerrainPopulation {
    struct Cache: Sendable {
        var documentID: UUID?
        var rules: [UUID: MeshTerrainPopulationRule] = [:]
        var cells: [CellKey: CachedCell] = [:]
        var influences: [UInt32: Influence] = [:]
    }

    struct CellKey: Hashable, Sendable {
        let rule: UUID
        let coordinate: SIMD3<Int32>
    }

    struct CachedCell: Sendable {
        let sample: MeshTerrainBounds
        let core: MeshTerrainBounds
        let patchGenerations: [UUID]
        let geometry: Data
        let mask: Data
        let sources: [UUID]
        let placements: [MeshTerrainPlacement]
    }

    struct Influence: Sendable {
        let sourceID: UInt32
        let generation = UUID()
        let surface: TriangleSurface
        let solid: ScalarMeshSolid
        let bounds: MeshTerrainBounds
    }

    struct IndexedPatch: Sendable {
        let value: MeshTerrainPatch
        let bounds: MeshTerrainBounds
    }

    struct CellPass {
        let maximumCandidates: Int
        let previous: Cache
        let indexedPatches: [IndexedPatch]
        let influences: [MeshTerrainPopulationInfluence]
        var staged: Cache
        var queryBudget: TriangleSurfaceQueryBudget
        var visitedCandidates = 0
        var neighborVisits = 0
        private var cellCount = 0
        private var recordCount = 0
        private var cachedBytes = 0
        private var sourceSolids: [Influence]?

        init(surface: MeshTerrainSurfaceSnapshot, previous: Cache, maximumCandidates: Int) throws {
            self.maximumCandidates = maximumCandidates
            self.previous = previous.documentID == surface.documentID ? previous : Cache()
            staged = Cache(documentID: surface.documentID)
            influences = surface.populationInfluences
            indexedPatches = surface.patches.compactMap { patch in
                patch.query.bounds.map { .init(value: patch, bounds: .init(minimum: $0.min, maximum: $0.max)) }
            }
            queryBudget = try .init(maximumWork: 134_217_728)
        }

        mutating func generate(
            _ rule: MeshTerrainPopulationRule, document: MeshTerrainDocument?, exclusions: [MeshTerrainBounds]
        ) throws -> [MeshTerrainPlacement] {
            guard rule.enabled, rule.density > 0 else { return [] }
            let coverage: MeshTerrainResolvedCoverage?
            let domain: MeshTerrainBounds
            if let input = rule.coverage {
                guard let document, document.id == staged.documentID else { throw TriangleGeometryError.invalidInput }
                let resolved = try input.resolve(in: document, limitedTo: rule.bounds)
                guard let volume = resolved.domain else { return [] }
                coverage = resolved
                domain = volume
            } else {
                coverage = nil
                domain = rule.bounds
            }

            var coreRule = rule
            coreRule.coverage = nil
            staged.rules[rule.id] = coreRule
            let canReuse = previous.rules[rule.id] == coreRule
            let sources = rule.sourceExclusionDistance != nil ? try preparedInfluences() : []
            let globalHalo = domain.expanded(by: rule.spacing)
            let grid = try coordinates(in: domain, size: rule.cellSize)
            var output: [MeshTerrainPlacement] = []
            for coordinate in grid {
                try queryBudget.charge()
                let key = CellKey(rule: rule.id, coordinate: coordinate)
                let core = Self.intersection(Self.bounds(coordinate, size: rule.cellSize), domain)
                let sample = Self.intersection(Self.bounds(coordinate, size: rule.cellSize).expanded(by: rule.spacing), globalHalo)
                let patches = indexedPatches.filter { $0.bounds.intersects(sample) }
                try queryBudget.charge(indexedPatches.count + exclusions.count + (coverage?.stamps.count ?? 0) + sources.count)
                let stamps = coverage?.stamps.filter { $0.bounds.intersects(sample) }
                let exclusions = exclusions.filter { $0.intersects(sample) }
                let nearby = sources.filter { $0.bounds.expanded(by: rule.sourceExclusionDistance ?? 0).intersects(sample) }
                let mask = try Self.maskKey(stamps: stamps, exclusions: exclusions)
                let cell = try evaluateCell(key, core: core, sample: sample, rule: rule, patches: patches, sources: nearby,
                                            coverage: stamps.map { .init(stamps: $0, domain: nil) }, exclusions: exclusions, mask: mask,
                                            cached: canReuse ? previous.cells[key] : nil)
                guard let cell else { continue }
                recordCount += cell.placements.count
                cachedBytes += 512 + cell.patchGenerations.count * 16 + cell.sources.count * 16 +
                    cell.placements.count * MemoryLayout<MeshTerrainPlacement>.stride
                guard recordCount <= maximumCandidates, cachedBytes <= 64 * 1_024 * 1_024 else { throw TriangleGeometryError.budgetExceeded }
                staged.cells[key] = cell
                output.append(contentsOf: cell.placements)
            }
            return output
        }

        private mutating func evaluateCell(
            _ key: CellKey, core: MeshTerrainBounds, sample: MeshTerrainBounds, rule: MeshTerrainPopulationRule,
            patches: [IndexedPatch], sources: [Influence], coverage: MeshTerrainResolvedCoverage?, exclusions: [MeshTerrainBounds],
            mask: Data, cached: CachedCell?
        ) throws -> CachedCell? {
            let patchGenerations = patches.map(\.value.generation), sourceGenerations = sources.map(\.generation)
            if let cached, cached.sample == sample, cached.core == core, cached.patchGenerations == patchGenerations,
                cached.mask == mask, cached.sources == sourceGenerations {
                return cached
            }
            guard let geometry = try Self.fingerprint(sample, patches: patches, budget: &queryBudget) else { return nil }
            let placements: [MeshTerrainPlacement]
            if let cached, cached.sample == sample, cached.core == core, cached.geometry == geometry,
                cached.mask == mask, cached.sources == sourceGenerations {
                placements = cached.placements
            } else {
                placements = try sampleCell(key.coordinate, core: core, halo: sample, rule: rule, patches: patches,
                                            influences: sources, coverage: coverage, exclusions: exclusions)
            }
            return .init(sample: sample, core: core, patchGenerations: patchGenerations, geometry: geometry, mask: mask,
                         sources: sourceGenerations, placements: placements)
        }

        private mutating func coordinates(in domain: MeshTerrainBounds, size: Float) throws -> [SIMD3<Int32>] {
            var result: Set<SIMD3<Int32>> = []
            for patch in indexedPatches where patch.bounds.intersects(domain) {
                let volume = Self.intersection(domain, patch.bounds)
                let low = Self.coordinate(volume.minimum, size: size), high = Self.coordinate(volume.maximum, size: size)
                let count = (Int64(high.x) - Int64(low.x) + 1) * (Int64(high.y) - Int64(low.y) + 1)
                guard count <= 16_384, count * (Int64(high.z) - Int64(low.z) + 1) <= 16_384 else { throw TriangleGeometryError.budgetExceeded }
                for z in low.z...high.z {
                    for y in low.y...high.y {
                        for x in low.x...high.x {
                            try queryBudget.charge()
                            if result.insert(SIMD3(x, y, z)).inserted {
                                cellCount += 1
                                guard cellCount <= 16_384 else { throw TriangleGeometryError.budgetExceeded }
                            }
                        }
                    }
                }
            }
            return result.sorted { a, b in
                if a.z != b.z { return a.z < b.z }
                if a.y != b.y { return a.y < b.y }
                return a.x < b.x
            }
        }

        private mutating func preparedInfluences() throws -> [Influence] {
            if let sourceSolids { return sourceSolids }
            guard influences.count <= 512 else { throw TriangleGeometryError.budgetExceeded }
            var remaining = 64 * 1_024 * 1_024
            var results: [Influence] = []
            for input in influences {
                try Task.checkCancellation()
                let surface = input.surface
                let charge = surface.positions.count * 64 + surface.indices.count / 3 * TriangleSurfaceIndex.bytesPerTriangle
                guard charge <= remaining else { throw TriangleGeometryError.budgetExceeded }
                remaining -= charge
                let value: Influence
                if let previous = previous.influences[input.sourceID], previous.surface == surface {
                    value = previous
                } else {
                    let solid = try ScalarMeshSolid(positions: surface.positions, indices: surface.indices)
                    value = .init(sourceID: input.sourceID, surface: surface, solid: solid, bounds: .init(minimum: solid.bounds.min, maximum: solid.bounds.max))
                }
                staged.influences[input.sourceID] = value
                results.append(value)
            }
            sourceSolids = results
            return results
        }

        static func coordinate(_ point: Vector3, size: Float) -> SIMD3<Int32> {
            SIMD3(Int32(floor(Double(point.x) / Double(size))), Int32(floor(Double(point.y) / Double(size))), Int32(floor(Double(point.z) / Double(size))))
        }

        private static func bounds(_ coordinate: SIMD3<Int32>, size: Float) -> MeshTerrainBounds {
            func corner(_ c: SIMD3<Int32>) -> Vector3 { Vector3(Float(c.x) * size, Float(c.y) * size, Float(c.z) * size) }
            // Conservative round-off padding: exact owner is determined in Double.
            let low = corner(coordinate), high = corner(coordinate &+ SIMD3(repeating: 1))
            return .init(minimum: [low.x.nextDown, low.y.nextDown, low.z.nextDown], maximum: [high.x.nextUp, high.y.nextUp, high.z.nextUp])
        }

        private static func intersection(_ first: MeshTerrainBounds, _ second: MeshTerrainBounds) -> MeshTerrainBounds {
            .init(minimum: max(first.minimum, second.minimum), maximum: min(first.maximum, second.maximum))
        }

        private struct Mask: Encodable {
            let stamps: [MeshTerrainResolvedCoverage.Stamp]?
            let exclusions: [MeshTerrainBounds]
        }

        private static func maskKey(stamps: [MeshTerrainResolvedCoverage.Stamp]?, exclusions: [MeshTerrainBounds]) throws -> Data {
            guard stamps != nil || !exclusions.isEmpty else { return Data() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return MeshTerrainContentKey.digest(try encoder.encode(Mask(stamps: stamps, exclusions: exclusions)))
        }
    }
}

extension MeshTerrainPopulation.CellPass {
    /// Includes exact ordered vertices and ownership, while ignoring face array order.
    /// Ray tie-breaking uses the same tokens so reordering coincident faces is safe.
    struct Face: Comparable {
        let words: SIMD16<UInt32>

        init(_ surface: TriangleSurface, _ face: Int) {
            var token = SIMD16<UInt32>(repeating: 0)
            token[0] = surface.faceSources.isEmpty ? 0 : surface.faceSources[face]
            for corner in 0..<3 {
                let point = surface.positions[Int(surface.indices[face * 3 + corner])]
                for axis in 0..<3 { token[1 + corner * 3 + axis] = point[axis].bitPattern }
            }
            words = token
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            for index in 0..<10 where lhs.words[index] != rhs.words[index] {
                return lhs.words[index] < rhs.words[index]
            }
            return false
        }
    }

    private static func fingerprint(
        _ halo: MeshTerrainBounds, patches: [MeshTerrainPopulation.IndexedPatch], budget: inout TriangleSurfaceQueryBudget
    ) throws -> Data? {
        var tokens = Data()
        for patch in patches {
            try budget.charge()
            var faces: [Face] = []
            try patch.value.query.visitTriangles(overlapping: .init(min: halo.minimum, max: halo.maximum), budget: &budget) { face in
                guard faces.count < 65_536 else { throw TriangleGeometryError.budgetExceeded }
                faces.append(.init(patch.value.surface, face))
            }
            guard !faces.isEmpty else { continue }
            let sortCost = max(1, Int.bitWidth - faces.count.leadingZeroBitCount)
            try budget.charge(faces.count * (sortCost + 10))
            faces.sort()
            // A bounded, fixed-width fingerprint; preserve patch order for equal hits.
            guard tokens.count + faces.count * 40 + 40 <= 8 * 1_024 * 1_024 else { throw TriangleGeometryError.budgetExceeded }
            tokens.append(contentsOf: patch.value.id.uuidString.utf8)
            add(UInt32(faces.count), to: &tokens)
            for face in faces {
                for index in 0..<10 { add(face.words[index], to: &tokens) }
            }
        }
        return tokens.isEmpty ? nil : MeshTerrainContentKey.digest(tokens)
    }

    private static func add(_ value: UInt32, to bytes: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
