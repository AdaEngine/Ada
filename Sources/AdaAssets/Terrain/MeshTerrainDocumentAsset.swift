import AdaGeometry
import Foundation
import Math

/// Immutable authoring document plus optional compiled product. Compiled players
/// consume accepted geometry and placement records without running editor kernels.
public struct MeshTerrainDocumentAsset: Asset {
    public static let maximumEncodedBytes: Int? = 32 * 1_024 * 1_024
    public var assetMetaInfo: AssetMetaInfo?
    public let document: MeshTerrainDocument
    public let populationRules: [MeshTerrainPopulationRule]
    public let manualPlacements: [MeshTerrainPlacement]
    public let populationOverrides: [MeshTerrainPopulationOverride]
    public let compiled: MeshTerrainCompiledProduct?

    public init(document: MeshTerrainDocument, populationRules: [MeshTerrainPopulationRule] = [],
                manualPlacements: [MeshTerrainPlacement] = [], populationOverrides: [MeshTerrainPopulationOverride] = [],
                compiled: MeshTerrainCompiledProduct? = nil) {
        self.document = document; self.populationRules = populationRules; self.manualPlacements = manualPlacements
        self.populationOverrides = populationOverrides; self.compiled = compiled
    }

    private struct Payload: Codable {
        let version: Int
        let document: MeshTerrainDocument
        let populationRules: [MeshTerrainPopulationRule]
        let manualPlacements: [MeshTerrainPlacement]
        let populationOverrides: [MeshTerrainPopulationOverride]
        let compiled: MeshTerrainCompiledProduct?
        private enum CodingKeys: CodingKey { case version, document, populationRules, manualPlacements, populationOverrides, compiled }
        init(version: Int, document: MeshTerrainDocument, populationRules: [MeshTerrainPopulationRule], manualPlacements: [MeshTerrainPlacement],
             populationOverrides: [MeshTerrainPopulationOverride], compiled: MeshTerrainCompiledProduct?) {
            self.version = version; self.document = document; self.populationRules = populationRules; self.manualPlacements = manualPlacements
            self.populationOverrides = populationOverrides; self.compiled = compiled
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == 1 else { throw TriangleGeometryError.invalidInput }
            document = try container.decode(MeshTerrainDocument.self, forKey: .document)
            populationRules = try MeshTerrainDecoding.list(MeshTerrainPopulationRule.self, key: .populationRules, in: container, decoder: decoder, maximum: 128)
            manualPlacements = try MeshTerrainDecoding.list(MeshTerrainPlacement.self, key: .manualPlacements, in: container, decoder: decoder, maximum: 262_144)
            populationOverrides = try MeshTerrainDecoding.list(MeshTerrainPopulationOverride.self, key: .populationOverrides, in: container, decoder: decoder, maximum: 262_144)
            compiled = try container.decodeIfPresent(MeshTerrainCompiledProduct.self, forKey: .compiled)
        }
    }

    public init(data: Data) throws {
        guard data.count <= (Self.maximumEncodedBytes ?? 0) else { throw TriangleGeometryError.budgetExceeded }
        let decoder = JSONDecoder()
        if let key = MeshTerrainDecodingBudget.key { decoder.userInfo[key] = MeshTerrainDecodingBudget() }
        let payload = try decoder.decode(Payload.self, from: data)
        guard payload.version == 1 else { throw TriangleGeometryError.invalidInput }
        self.init(document: payload.document, populationRules: payload.populationRules, manualPlacements: payload.manualPlacements,
                  populationOverrides: payload.populationOverrides, compiled: payload.compiled)
        try validate()
    }

    public func validate() throws {
        try document.validate()
        guard populationRules.count <= 128, manualPlacements.count <= 262_144, populationOverrides.count <= 262_144,
            Set(populationRules.map(\.id)).count == populationRules.count, Set(manualPlacements.map(\.id)).count == manualPlacements.count else {
            throw TriangleGeometryError.budgetExceeded
        }
        for rule in populationRules { try rule.validate() }
        for placement in manualPlacements { try placement.validate() }
        for override in populationOverrides {
            try override.pinned?.validate()
            guard populationRules.contains(where: { $0.id == override.ruleID }),
                override.pinned == nil || override.pinned?.id == override.candidateID else { throw TriangleGeometryError.invalidInput }
        }
        try compiled?.validate()
        if let compiled {
            let knownStrokes = Set(document.paint.map(\.id))
            guard compiled.paintOrphans?.allSatisfy(knownStrokes.contains) != false,
                !knownStrokes.isEmpty || compiled.patches.allSatisfy({ $0.paint == nil }) else {
                throw TriangleGeometryError.invalidInput
            }
        }
    }

    public func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(version: 1, document: document, populationRules: populationRules,
                                              manualPlacements: manualPlacements, populationOverrides: populationOverrides, compiled: compiled))
        guard data.count <= (Self.maximumEncodedBytes ?? 0) else { throw TriangleGeometryError.budgetExceeded }
        return data
    }

    public init(from assetDecoder: any AssetDecoder) async throws { try self.init(data: assetDecoder.assetData) }
    public func encodeContents(with assetEncoder: any AssetEncoder) async throws { try assetEncoder.encode(encodedData()) }
    public static func extensions() -> [String] { ["atmesh"] }
}

public struct MeshTerrainCompiledProduct: Codable, Equatable, Sendable {
    public let inputKey: Data
    public let patches: [MeshTerrainCompiledPatch]
    public let placements: [MeshTerrainPlacement]
    /// Authored strokes for which a compatible visible surface could not be found.
    public let paintOrphans: [UUID]?
    public let orphanedPins: [MeshTerrainPlacement]?

    public init(inputKey: Data, patches: [MeshTerrainCompiledPatch], placements: [MeshTerrainPlacement],
                paintOrphans: [UUID]? = nil, orphanedPins: [MeshTerrainPlacement]? = nil) {
        self.inputKey = inputKey; self.patches = patches; self.placements = placements
        self.paintOrphans = paintOrphans; self.orphanedPins = orphanedPins
    }

    private enum CodingKeys: CodingKey { case inputKey, patches, placements, paintOrphans, orphanedPins }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputKey = try container.decode(Data.self, forKey: .inputKey)
        patches = try MeshTerrainDecoding.list(MeshTerrainCompiledPatch.self, key: .patches, in: container, decoder: decoder, maximum: 128)
        placements = try MeshTerrainDecoding.list(MeshTerrainPlacement.self, key: .placements, in: container, decoder: decoder, maximum: 262_144)
        paintOrphans = try container.contains(.paintOrphans)
            ? MeshTerrainDecoding.list(UUID.self, key: .paintOrphans, in: container, decoder: decoder, maximum: 4_096)
            : nil
        orphanedPins = try container.contains(.orphanedPins)
            ? MeshTerrainDecoding.list(MeshTerrainPlacement.self, key: .orphanedPins, in: container, decoder: decoder, maximum: 262_144)
            : nil
    }
    public func validate() throws {
        guard inputKey.count == 32, patches.count <= 128, placements.count <= 262_144,
            Set(patches.map(\.id)).count == patches.count else { throw TriangleGeometryError.budgetExceeded }
        if let paintOrphans {
            guard paintOrphans.count <= 4_096, Set(paintOrphans).count == paintOrphans.count else { throw TriangleGeometryError.invalidInput }
        }
        var paintRows = 0
        for patch in patches {
            try patch.surface.validate()
            try patch.paint?.validate(cornerCount: patch.surface.indices.count)
            paintRows += patch.paint?.samples.count ?? 0
            guard paintRows <= 262_144 else { throw TriangleGeometryError.budgetExceeded }
        }
        for placement in placements { try placement.validate() }
        if let orphanedPins {
            guard orphanedPins.count <= 262_144, orphanedPins.allSatisfy({ $0.ownership == .pinned }) else {
                throw TriangleGeometryError.invalidInput
            }
            for pin in orphanedPins { try pin.validate() }
        }
    }
}

public struct MeshTerrainCompiledPatch: Codable, Equatable, Sendable {
    public let id: UUID
    public let surface: TriangleSurface
    public let paint: MeshTerrainCompiledPaint?
    public init(id: UUID, surface: TriangleSurface, paint: MeshTerrainCompiledPaint? = nil) {
        self.id = id; self.surface = surface; self.paint = paint
    }
}

extension MeshTerrainPlacement {
    public func validate() throws {
        try ScalarSolid.validateTransform(transform)
        guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else { throw TriangleGeometryError.invalidInput }
    }
}
