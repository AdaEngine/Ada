@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

/// Captures one terrain generation and coalesces stationary pointer samples.
/// A worker always evaluates a snapshot of the retained stamps, never the last preview's vertices.
@MainActor
final class EditorMeshTerrainSculptStroke {
    enum Tool {
        case shape(EditorTerrainBrushMode)
        case material(MeshTerrainPaintStamp.Operation)
        case population(Population)
    }

    struct Population: Sendable {
        let prototypeID: UInt16
        let density: Float
        let seed: UInt64
        let erases: Bool
    }

    private struct PaintStamp {
        let id = UUID()
        let anchor: MeshTerrainSurfaceAnchor
        var mix: Float
    }
    struct Hit {
        let editorID: String
        let owner: Entity
        let source: Terrain3DSource
        let surface: MeshTerrain3DSourceSurface
        let matrix: Transform3D
        let sample: TerrainSurfaceQueryHit
    }

    private struct Stamp {
        let id = UUID()
        let center: Vector3
        let normal: Vector3
        let target: SurfaceTarget?
        var displacement: Vector3
        var mix: Float
    }

    private struct SurfaceTarget: Equatable {
        let sectionID: UUID
        let sourceID: UInt32
    }

    let hit: Hit
    let ownership: MeshTerrain3DOwnership
    private let radius: Float
    private let strength: Float
    private let tool: Tool
    private let sourceIDs: [UInt32]
    private let firstOrder: Int
    private var stamps: [Stamp] = []
    private let newPopulationRule = UUID()
    private let populationRuleIndex: Int?
    private let maximumSurfaceStamps: Int
    private var paint: [PaintStamp] = []
    private(set) var revision: UInt64 = 0
    private(set) var exceededLimit = false
    var radiusForSampling: Float { radius }
    var previewQueries: TerrainSurfaceQueries?

    init(hit: Hit, ownership: MeshTerrain3DOwnership, radius: Float, strength: Float, tool: Tool) throws {
        guard radius.isFinite, radius > 0, strength.isFinite, strength > 0 else { throw TriangleGeometryError.invalidInput }
        if case .shape = tool {
            let modifiers = hit.surface.asset.document.modifiers
            let limit = min(64, 512 - modifiers.count), lastOrder = modifiers.map(\.order).max() ?? -1
            guard limit > 0, lastOrder <= Int.max - limit else { throw TriangleGeometryError.budgetExceeded }
            let occupied = Set(modifiers.map(\.sourceID))
            sourceIDs = Array((UInt32(1)...UInt32(513)).lazy.filter { !occupied.contains($0) }.prefix(limit))
            firstOrder = lastOrder + 1
            populationRuleIndex = nil; maximumSurfaceStamps = 0
        } else {
            sourceIDs = []; firstOrder = 0
            if case let .population(settings) = tool {
                let rules = hit.surface.asset.populationRules
                let index = rules.firstIndex { $0.prototypeID == settings.prototypeID && $0.coverage != nil }
                guard index != nil || rules.count < 128, settings.density.isFinite, (0...1).contains(settings.density) else {
                    throw TriangleGeometryError.budgetExceeded
                }
                populationRuleIndex = index
                maximumSurfaceStamps = MeshTerrainPopulationCoverage.maximumStamps - (index.flatMap { rules[$0].coverage?.stamps.count } ?? 0)
            } else {
                populationRuleIndex = nil
                maximumSurfaceStamps = 4_096 - hit.surface.asset.document.paint.count
            }
            guard maximumSurfaceStamps > 0 else { throw TriangleGeometryError.budgetExceeded }
        }
        self.hit = hit; self.ownership = ownership; self.radius = radius; self.strength = strength; self.tool = tool
        previewQueries = hit.surface.queries
    }

    func append(_ sample: TerrainSurfaceQueryHit, duration: Float) {
        guard !exceededLimit, duration.isFinite, duration > 0 else { return }
        let amount = strength * min(duration, 0.05)
        guard case let .shape(mode) = tool else {
            appendPaint(sample, amount: min(1, amount))
            return
        }
        let target: SurfaceTarget?
        let displacement: Vector3
        switch mode {
        case .raise, .lower:
            target = nil
            displacement = sample.normal * (mode == .lower ? -amount : amount)
        case .smooth, .flatten:
            guard let current = surfaceTarget(sample) else { return }
            target = current
            displacement = .zero
        }
        let mix = min(1, amount)
        let tolerance = max(0.01, radius * 0.1)
        if let last = stamps.indices.last, stamps[last].target == target, (stamps[last].center - sample.position).squaredLength < tolerance * tolerance {
            let combined = stamps[last].displacement + displacement
            guard combined.squaredLength <= 4_096 else { exceededLimit = true; return }
            stamps[last].displacement = combined
            stamps[last].mix += (1 - stamps[last].mix) * mix
        } else {
            guard stamps.count < sourceIDs.count, displacement.squaredLength <= 4_096 else { exceededLimit = true; return }
            stamps.append(.init(center: sample.position, normal: sample.normal, target: target, displacement: displacement, mix: mix))
        }
        revision &+= 1
    }

    func candidate() -> MeshTerrainDocumentAsset {
        let initial = hit.surface.asset
        if case let .population(settings) = tool { return populationCandidate(initial, settings: settings) }
        var document = initial.document
        if case let .material(operation) = tool {
            document.paint += paint.map { .init(id: $0.id, anchor: $0.anchor, radius: radius, strength: $0.mix, operation: operation) }
            return .init(document: document, populationRules: initial.populationRules, manualPlacements: initial.manualPlacements,
                populationOverrides: initial.populationOverrides)
        }
        guard case let .shape(mode) = tool else { return initial }
        let operand = TriangleSurface(positions: [], indices: [])
        for (index, stamp) in stamps.enumerated() {
            let operation: MeshTerrainModifierOperation
            switch mode {
            case .raise, .lower:
                operation = .sculpt(center: stamp.center, radius: radius, displacement: stamp.displacement)
            case .smooth, .flatten:
                guard let target = stamp.target else { continue }
                let normal = mode == .flatten ? hit.sample.normal : stamp.normal
                let action: MeshTerrainSurfaceSculpt.Operation = mode == .flatten ? .flatten(point: hit.sample.position) : .smooth
                operation = .surfaceSculpt(.init(sectionID: target.sectionID, center: stamp.center, normal: normal, sourceID: target.sourceID,
                    radius: radius, strength: stamp.mix, operation: action))
            }
            document.modifiers.append(.init(id: stamp.id, sourceID: sourceIDs[index], operation: operation, surface: operand, order: firstOrder + index))
        }
        return .init(document: document, populationRules: initial.populationRules, manualPlacements: initial.manualPlacements,
            populationOverrides: initial.populationOverrides)
    }

    private func populationCandidate(_ initial: MeshTerrainDocumentAsset, settings: Population) -> MeshTerrainDocumentAsset {
        guard !paint.isEmpty else { return initial }
        var rules = initial.populationRules
        let index: Int
        if let populationRuleIndex { index = populationRuleIndex }
        else {
            if settings.erases { return initial }
            index = rules.count
            // Brush coverage derives the actual bounded sample domain at compile time.
            let possible = MeshTerrainBounds(minimum: Vector3(-1_000_000), maximum: Vector3(1_000_000))
            rules.append(.init(id: newPopulationRule, prototypeID: settings.prototypeID, seed: settings.seed, bounds: possible,
                density: 1, spacing: 0.8))
        }
        let operation: MeshTerrainPopulationCoverage.Stamp.Operation = settings.erases ? .erase : .include(density: settings.density)
        let authored = rules[index].coverage?.stamps ?? []
        rules[index].coverage = .init(stamps: authored + paint.map { .init(anchor: $0.anchor, radius: radius, operation: operation) })
        return .init(document: initial.document, populationRules: rules, manualPlacements: initial.manualPlacements,
            populationOverrides: initial.populationOverrides)
    }

    private func appendPaint(_ sample: TerrainSurfaceQueryHit, amount: Float) {
        let document = hit.surface.asset.document
        guard let patch = patch(for: sample),
            let anchor = try? MeshTerrainSurfaceAnchor.capture(section: patch.id, surface: patch.surface, hit: sample.surface, document: document) else { return }
        let tolerance = max(0.01, radius * 0.1)
        if let last = paint.indices.last, paint[last].anchor.frame == anchor.frame, paint[last].anchor.section == anchor.section,
            paint[last].anchor.normal.dot(anchor.normal) >= 0.5,
            (paint[last].anchor.point - anchor.point).squaredLength < tolerance * tolerance {
            if case .population = tool { return }
            if case .material(.erase) = tool { paint[last].mix = min(1, paint[last].mix + amount) }
            else { paint[last].mix += (1 - paint[last].mix) * amount }
        } else {
            guard paint.count < min(64, maximumSurfaceStamps) else { exceededLimit = true; return }
            paint.append(.init(anchor: anchor, mix: amount))
        }
        revision &+= 1
    }

    private func patch(for sample: TerrainSurfaceQueryHit) -> MeshTerrainCompiledPatch? {
        guard let patches = hit.surface.asset.compiled?.patches, sample.coordinate.z == 0,
            patches.indices.contains(sample.coordinate.x) else { return nil }
        return patches[sample.coordinate.x]
    }

    private func surfaceTarget(_ sample: TerrainSurfaceQueryHit) -> SurfaceTarget? {
        guard let patch = patch(for: sample) else { return nil }
        let face = sample.surface.triangleIndex
        guard (0..<patch.surface.indices.count / 3).contains(face) else { return nil }
        let source = patch.surface.faceSources.isEmpty ? 0 : patch.surface.faceSources[face]
        return .init(sectionID: patch.id, sourceID: source)
    }

    /// Stages one coherent runtime generation. Cancellation withdraws only this request.
    func publish(_ candidate: MeshTerrainDocumentAsset, application: AppWorlds, isCurrent: () -> Bool) async throws -> MeshTerrain3DSourceSurface {
        let owner = hit.owner, original = hit.source
        var requestID: UUID?
        do {
            let resident = try await application.withWorldAccess { () throws -> MeshTerrain3DSourceSurface? in
                guard isCurrent(), application.main.getEntityByID(owner.id) === owner,
                    owner.components[Terrain3DSource.self] == original,
                    let surface = owner.components[MeshTerrain3DSourceSurface.self], let key = surface.asset.compiled?.inputKey,
                    owner.components[MeshTerrain3DEdit.self] == nil else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                if candidate.compiled?.inputKey == key { return surface }
                let request = MeshTerrain3DEdit(expectedInputKey: key, candidate: candidate)
                requestID = request.id
                owner.components[MeshTerrain3DEdit.self] = request
                return nil
            }
            if let resident { return resident }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                if let applied = try await application.withWorldAccess({ () throws -> MeshTerrain3DSourceSurface? in
                    guard isCurrent(), application.main.getEntityByID(owner.id) === owner else { throw CancellationError() }
                    guard let status = owner.components[MeshTerrain3DEditStatus.self], status.id == requestID else { return nil }
                    switch status.phase {
                    case .pending: return nil
                    case .failed: throw EditorTerrainSourceAuthoring.Failure.failed(status.error ?? "Mesh Terrain could not be updated.")
                    case .cancelled: throw CancellationError()
                    case .applied:
                        guard let surface = owner.components[MeshTerrain3DSourceSurface.self] else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                        return surface
                    }
                }) { return applied }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw EditorTerrainSourceAuthoring.Failure.timedOut
        } catch {
            if let requestID {
                await Task { @MainActor in
                    try? await application.withWorldAccess {
                        if application.main.getEntityByID(owner.id) === owner, owner.components[MeshTerrain3DEdit.self]?.id == requestID {
                            owner.components.remove(MeshTerrain3DEdit.self)
                        }
                    }
                }.value
            }
            throw error
        }
    }
}
