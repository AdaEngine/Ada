import Foundation
import Math

public enum MeshTerrainClosure: Codable, Equatable, Sendable {
    case closed
    case ground(bottomHeight: Float)
}

public struct MeshTerrainBaseSection: Codable, Equatable, Sendable {
    public let id: UUID
    public var surface: TriangleSurface
    public var closure: MeshTerrainClosure
    public init(id: UUID = UUID(), surface: TriangleSurface, closure: MeshTerrainClosure = .closed) {
        self.id = id; self.surface = surface; self.closure = closure
    }
}

public enum MeshTerrainModifierOperation: Codable, Equatable, Sendable {
    case union, subtract
    case conform(direction: Vector3, distance: Float, strength: Float)
    case refine(targetEdgeLength: Float, iterations: Int)
    case sculpt(center: Vector3, radius: Float, displacement: Vector3)
    case surfaceSculpt(MeshTerrainSurfaceSculpt)
}

/// Optional geometric relaxation around a joined seam, in terrain-local units.
/// The permitted movement is independent of the material transition width.
public struct MeshTerrainRounding: Codable, Equatable, Sendable {
    public var radius: Float
    public var maximumDeviation: Float

    public init(radius: Float, maximumDeviation: Float) {
        self.radius = radius
        self.maximumDeviation = maximumDeviation
    }
}

/// Retained static source and placement. Entity bindings are stable serialized IDs,
/// resolved by the editor; geometry workers never capture live scene entities.
public struct MeshTerrainModifier: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceID: UInt32
    public var operation: MeshTerrainModifierOperation
    public var surface: TriangleSurface
    public var transform: Transform3D
    public var enabled: Bool
    public var order: Int
    public var entityID: UUID?
    public var sourcePath: String?
    public var materialLayer: UInt16?
    public var contactWidth: Float
    public var rounding: MeshTerrainRounding?
    public var sourceAppearance: MeshTerrainSourceAppearance?

    public init(id: UUID = UUID(), sourceID: UInt32, operation: MeshTerrainModifierOperation, surface: TriangleSurface,
                transform: Transform3D = .identity, enabled: Bool = true, order: Int = 0, entityID: UUID? = nil,
                sourcePath: String? = nil, materialLayer: UInt16? = nil, contactWidth: Float = 1, rounding: MeshTerrainRounding? = nil,
                sourceAppearance: MeshTerrainSourceAppearance? = nil) {
        self.id = id; self.sourceID = sourceID; self.operation = operation; self.surface = surface; self.transform = transform
        self.enabled = enabled; self.order = order; self.entityID = entityID; self.sourcePath = sourcePath
        self.materialLayer = materialLayer; self.contactWidth = contactWidth
        self.rounding = rounding
        self.sourceAppearance = sourceAppearance
    }
}

public struct MeshTerrainDocument: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public var version: Int
    public let id: UUID
    public var sections: [MeshTerrainBaseSection]
    public var modifiers: [MeshTerrainModifier]
    public var paint: [MeshTerrainPaintStamp]

    public init(id: UUID = UUID(), sections: [MeshTerrainBaseSection], modifiers: [MeshTerrainModifier] = []) {
        version = Self.formatVersion; self.id = id; self.sections = sections; self.modifiers = modifiers
        paint = []
    }

    private enum CodingKeys: String, CodingKey { case version, id, sections, modifiers, paint }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else { throw TriangleGeometryError.invalidInput }
        id = try container.decode(UUID.self, forKey: .id)
        sections = try MeshTerrainDecoding.list(MeshTerrainBaseSection.self, key: .sections, in: container, decoder: decoder, maximum: 128)
        modifiers = try MeshTerrainDecoding.list(MeshTerrainModifier.self, key: .modifiers, in: container, decoder: decoder, maximum: 512)
        paint = try container.contains(.paint)
            ? MeshTerrainDecoding.list(MeshTerrainPaintStamp.self, key: .paint, in: container, decoder: decoder, maximum: 4_096)
            : []
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(sections, forKey: .sections)
        try container.encode(modifiers, forKey: .modifiers)
        // Preserve the canonical key of pre-paint documents and their compiled geometry.
        if !paint.isEmpty { try container.encode(paint, forKey: .paint) }
    }

    public func validate() throws {
        guard version == Self.formatVersion, !sections.isEmpty, sections.count <= 128, modifiers.count <= 512,
            Set(sections.map(\.id)).count == sections.count, Set(modifiers.map(\.id)).count == modifiers.count,
            Set(modifiers.map(\.sourceID)).count == modifiers.count,
            modifiers.allSatisfy({ $0.sourceID > 0 && $0.sourceID < TrianglePatchClosure.closureSource && $0.contactWidth.isFinite && $0.contactWidth >= 0 })
        else { throw TriangleGeometryError.invalidInput }
        guard paint.count <= 4_096, Set(paint.map(\.id)).count == paint.count else { throw TriangleGeometryError.budgetExceeded }
        for stamp in paint { try stamp.validate() }
        for section in sections {
            try section.surface.validate()
            guard section.surface.faceSources.allSatisfy({ $0 == 0 }), !section.surface.indices.isEmpty else { throw TriangleGeometryError.invalidInput }
            if case let .ground(bottomHeight) = section.closure { guard bottomHeight.isFinite else { throw TriangleGeometryError.invalidInput } }
        }
        for modifier in modifiers {
            try modifier.surface.validate()
            try modifier.sourceAppearance?.validate(faceCount: modifier.surface.indices.count / 3, vertexCount: modifier.surface.positions.count)
            try ScalarSolid.validateTransform(modifier.transform)
            if let rounding = modifier.rounding {
                guard modifier.operation == .union, rounding.radius.isFinite, rounding.radius > 0, rounding.radius <= 32,
                    rounding.maximumDeviation.isFinite, rounding.maximumDeviation > 0, rounding.maximumDeviation <= rounding.radius else {
                    throw TriangleGeometryError.invalidInput
                }
            }
            switch modifier.operation {
            case .union, .subtract: guard !modifier.surface.indices.isEmpty else { throw TriangleGeometryError.invalidInput }
            case let .conform(direction, distance, strength):
                guard direction.squaredLength > 0, direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
                    distance.isFinite, distance > 0, strength.isFinite, (0...1).contains(strength) else { throw TriangleGeometryError.invalidInput }
            case let .refine(length, iterations):
                guard length.isFinite, length > 0, (1...6).contains(iterations) else { throw TriangleGeometryError.invalidInput }
            case let .sculpt(center, radius, displacement):
                guard center.x.isFinite, center.y.isFinite, center.z.isFinite, radius.isFinite, radius > 0,
                    displacement.x.isFinite, displacement.y.isFinite, displacement.z.isFinite else { throw TriangleGeometryError.invalidInput }
            case let .surfaceSculpt(stamp): try stamp.validate()
            }
        }
    }

    public func canonicalData() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct MeshTerrainPatch: Sendable {
    public let id: UUID
    public let generation: UUID
    public let surface: TriangleSurface
    public let query: TriangleSurfaceIndex
    public let inputKey: Data
}

/// Retained static source geometry used for precise population clearance.
public struct MeshTerrainPopulationInfluence: Sendable {
    public let sourceID: UInt32
    public let surface: TriangleSurface
}

public struct MeshTerrainSurfaceSnapshot: Sendable {
    let revision: UUID
    public let documentID: UUID
    public let patches: [MeshTerrainPatch]
    public let populationInfluences: [MeshTerrainPopulationInfluence]
    public let reusedPatchCount: Int
    public let rebuiltPatchCount: Int

    public func raycast(_ ray: Ray, maximumDistance: Float = 100_000) throws -> (patch: UUID, hit: TriangleSurfaceHit)? {
        var budget = try TriangleSurfaceQueryBudget(maximumWork: 1_048_576)
        var result: (patch: UUID, hit: TriangleSurfaceHit)?
        for patch in patches {
            if let hit = try patch.query.raycast(ray, maximumDistance: min(maximumDistance, result?.hit.distance.nextUp ?? maximumDistance), budget: &budget),
                result == nil || hit.preciseDistance < (result?.hit.preciseDistance ?? .infinity) { result = (patch.id, hit) }
        }
        return result
    }
}
