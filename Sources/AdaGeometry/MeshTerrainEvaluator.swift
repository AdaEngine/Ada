import Foundation
import Math

/// Retained input evaluation. Reuses unchanged sections and never publishes a
/// superseded call. A caller swaps its accepted source transforms/draw masks with
/// the returned snapshot, keeping provisional drag state separate.
public actor MeshTerrainEvaluator {
    private typealias Operation = (record: MeshTerrainModifier, surface: TriangleSurface, bounds: MeshTerrainBounds?)
    private typealias SectionPlan = (section: MeshTerrainBaseSection, bounds: MeshTerrainBounds, operations: [Operation])

    private struct Cached {
        let key: Data
        let patch: MeshTerrainPatch
        let bytes: Int
    }
    private var cache: [UUID: Cached] = [:]
    private var request = UUID()
    private var populationCache = MeshTerrainPopulation.Cache()
    public private(set) var lastAccepted: MeshTerrainSurfaceSnapshot?

    public init() {}

    public func evaluate(_ document: MeshTerrainDocument, budget: TriangleGeometryBudget = .init()) async throws -> MeshTerrainSurfaceSnapshot {
        try document.validate()
        try Task.checkCancellation()
        let token = UUID(); request = token
        let operations = try document.modifiers.filter(\.enabled).sorted {
            $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
        }.map { modifier -> Operation in
            var surface = try modifier.surface.transformed(by: modifier.transform)
            surface.faceSources = Array(repeating: modifier.sourceID, count: surface.indices.count / 3)
            return (modifier, surface, surface.bounds)
        }
        let plans = try Self.planSections(document.sections, operations: operations, budget: budget)
        var staged: [UUID: Cached] = [:], patches: [MeshTerrainPatch] = []
        var bytes = 0, reused = 0, rebuilt = 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (section, sectionBounds, relevant) in plans {
            try Task.checkCancellation()
            let ground: Bool
            if case .ground = section.closure { ground = true } else { ground = false }
            var canonical = Data("AdaMeshTerrain.section.v1.manifold3.5.1".utf8)
            canonical.append(try encoder.encode(section))
            canonical.append(try encoder.encode(relevant.map(\.record)))
            canonical.append(try encoder.encode([budget.maximumInputTriangles, budget.maximumOutputTriangles, budget.maximumBytes, budget.maximumCandidatePairs]))
            let key = MeshTerrainContentKey.digest(canonical)
            if let previous = cache[section.id], previous.key == key {
                bytes += previous.bytes
                guard bytes <= budget.maximumBytes else { throw TriangleGeometryError.budgetExceeded }
                patches.append(previous.patch); staged[section.id] = previous; reused += 1
                continue
            }
            var surface = section.surface
            if case let .ground(bottomHeight) = section.closure { surface = try TrianglePatchClosure.closeGround(surface, below: bottomHeight) }
            for operation in relevant {
                try Task.checkCancellation()
                guard request == token else { throw CancellationError() }
                switch operation.record.operation {
                case .union, .subtract:
                    var operand = operation.surface
                    if case let .ground(bottomHeight) = section.closure, let bounds = operation.bounds {
                        guard bounds.minimum.y > bottomHeight else { throw TriangleGeometryError.invalidInput }
                        if bounds.minimum.x < sectionBounds.minimum.x || bounds.maximum.x > sectionBounds.maximum.x ||
                            bounds.minimum.z < sectionBounds.minimum.z || bounds.maximum.z > sectionBounds.maximum.z {
                            let clip = try TriangleSurface.box(minimum: [sectionBounds.minimum.x, bottomHeight, sectionBounds.minimum.z],
                                                              maximum: [sectionBounds.maximum.x, max(sectionBounds.maximum.y, bounds.maximum.y) + 1, sectionBounds.maximum.z],
                                                              source: TrianglePatchClosure.closureSource)
                            operand = try await TriangleMeshBoolean.applyCancellable(.intersect, base: operand, operand: clip, budget: budget)
                        }
                    }
                    if !operand.indices.isEmpty {
                        surface = try await TriangleMeshBoolean.applyCancellable(operation.record.operation == .union ? .union : .subtract,
                                                                                 base: surface, operand: operand, budget: budget)
                        if let rounding = operation.record.rounding {
                            surface = try TriangleContactRelaxation.apply(surface, operand: operation.record.sourceID, options: rounding, budget: budget)
                        }
                    }
                case .conform, .refine, .sculpt, .surfaceSculpt:
                    surface = try TriangleSurfaceEditing.apply(operation.record.operation, to: surface, operand: operation.surface, budget: budget)
                }
            }
            if ground { surface = try TrianglePatchClosure.visibleSurface(surface) }
            let query = try TriangleSurfaceIndex(positions: surface.positions, indices: surface.indices,
                                                 maximumBytes: max(0, budget.maximumBytes - bytes), maximumWork: 67_108_864)
            let charged = surface.positions.count * 64 + surface.indices.count * 8 + query.chargedBytes + key.count
            guard charged <= budget.maximumBytes - bytes else { throw TriangleGeometryError.budgetExceeded }
            bytes += charged
            let patch = MeshTerrainPatch(id: section.id, generation: UUID(), surface: surface, query: query, inputKey: key)
            patches.append(patch); staged[section.id] = .init(key: key, patch: patch, bytes: charged); rebuilt += 1
        }
        guard request == token else { throw CancellationError() }
        try Task.checkCancellation()
        let influences = operations.compactMap { operation -> MeshTerrainPopulationInfluence? in
            if case .union = operation.record.operation { return .init(sourceID: operation.record.sourceID, surface: operation.surface) }
            return nil
        }
        let snapshot = MeshTerrainSurfaceSnapshot(revision: token, documentID: document.id, patches: patches, populationInfluences: influences, reusedPatchCount: reused, rebuiltPatchCount: rebuilt)
        cache = staged; lastAccepted = snapshot
        return snapshot
    }

    /// Evaluates population against the supplied geometry generation for this document.
    public func evaluatePopulation(
        _ rules: [MeshTerrainPopulationRule], surface: MeshTerrainSurfaceSnapshot,
        document: MeshTerrainDocument, manual: [MeshTerrainPlacement] = [], overrides: [MeshTerrainPopulationOverride] = []
    ) throws -> MeshTerrainPopulationSnapshot {
        guard surface.documentID == document.id else { throw TriangleGeometryError.invalidInput }
        guard surface.revision == request else { throw CancellationError() }
        return try MeshTerrainPopulation.evaluate(rules, surface: surface, document: document, manual: manual, overrides: overrides, cache: &populationCache)
    }

    public func cancel() { request = UUID() }

    private static func planSections(_ sections: [MeshTerrainBaseSection], operations: [Operation], budget: TriangleGeometryBudget) throws -> [SectionPlan] {
        var unclipped: Set<UUID> = []
        var clips: [UUID: [MeshTerrainBounds]] = [:]
        let plans: [SectionPlan] = try sections.map { section in
            try Task.checkCancellation()
            guard let sectionBounds = section.surface.bounds else { throw TriangleGeometryError.invalidInput }
            let ground: Bool
            if case .ground = section.closure { ground = true } else { ground = false }
            var influence = sectionBounds
            var relevant: [Operation] = []
            for operation in operations {
                let bounds = operation.bounds.map { bounds in
                    operation.record.rounding.map { bounds.expanded(by: $0.radius + $0.maximumDeviation) } ?? bounds
                }
                let affects: Bool
                switch operation.record.operation {
                case let .sculpt(center, radius, _): affects = influence.intersects(.init(minimum: center - Vector3(radius), maximum: center + Vector3(radius)), horizontal: ground)
                case let .surfaceSculpt(stamp):
                    let bounds = MeshTerrainBounds(minimum: stamp.center - Vector3(stamp.radius), maximum: stamp.center + Vector3(stamp.radius))
                    affects = (stamp.sectionID == nil || stamp.sectionID == section.id) && influence.intersects(bounds)
                case .refine: affects = bounds.map { influence.intersects($0, horizontal: ground) } ?? true
                default: affects = bounds.map { influence.intersects($0, horizontal: ground) } ?? false
                }
                if affects {
                    relevant.append(operation)
                    if let bounds { influence = influence.union(bounds) }
                    if case .union = operation.record.operation {
                        if ground { clips[operation.record.id, default: []].append(sectionBounds) }
                        else { unclipped.insert(operation.record.id) }
                    }
                }
            }
            return (section, sectionBounds, relevant)
        }
        var remaining = budget.maximumCandidatePairs
        for operation in operations where operation.record.operation == .union && !unclipped.contains(operation.record.id) {
            try Task.checkCancellation()
            guard let operand = operation.bounds,
                try MeshTerrainCoverage.contains(operand, in: clips[operation.record.id] ?? [], remaining: &remaining)
            else { throw TriangleGeometryError.operandOutsideTerrain }
        }
        return plans
    }
}
