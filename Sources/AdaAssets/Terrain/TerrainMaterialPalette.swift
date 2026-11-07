import Foundation

/// Bounded authoring palette. Display order never changes the stable IDs stored by paint and rules.
public struct TerrainMaterialPalette: Codable, Equatable, Sendable {
    public let layers: [TerrainLayerReference]
    public let fallbackLayerID: UInt16
    public let interiorLayerID: UInt16
    public let rules: [TerrainMaterialRule]

    public init(layers: [TerrainLayerReference], fallbackLayerID: UInt16, interiorLayerID: UInt16? = nil, rules: [TerrainMaterialRule] = []) {
        self.layers = layers; self.fallbackLayerID = fallbackLayerID; self.interiorLayerID = interiorLayerID ?? fallbackLayerID; self.rules = rules
    }

    private enum CodingKeys: CodingKey { case layers, fallbackLayerID, interiorLayerID, rules }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func list<Value: Decodable>(_ type: Value.Type, key: CodingKeys, maximum: Int) throws -> [Value] {
            guard container.contains(key) else {
                return []
            }
            var input = try container.nestedUnkeyedContainer(forKey: key)
            if let count = input.count, count > maximum { throw TerrainManifestError.malformed("terrain material palette count exceeded") }
            var values: [Value] = []
            while !input.isAtEnd {
                guard values.count < maximum else { throw TerrainManifestError.malformed("terrain material palette count exceeded") }
                values.append(try input.decode(type))
            }
            return values
        }
        self.init(
            layers: try list(TerrainLayerReference.self, key: .layers, maximum: 32),
            fallbackLayerID: try container.decode(UInt16.self, forKey: .fallbackLayerID),
            interiorLayerID: try container.decodeIfPresent(UInt16.self, forKey: .interiorLayerID),
            rules: try list(TerrainMaterialRule.self, key: .rules, maximum: 128)
        )
        try validate()
    }

    public func validate() throws {
        guard (1...32).contains(layers.count), rules.count <= 128 else { throw TerrainManifestError.malformed("invalid terrain material palette count") }
        var ids: Set<UInt16> = []
        for layer in layers {
            try layer.validate()
            guard ids.insert(layer.id).inserted else { throw TerrainManifestError.malformed("duplicate terrain material layer ID") }
        }
        guard ids.contains(fallbackLayerID), ids.contains(interiorLayerID) else { throw TerrainManifestError.malformed("missing terrain fallback layer") }
        for rule in rules {
            try rule.validate()
            guard ids.contains(rule.layerID) else { throw TerrainManifestError.malformed("missing terrain rule layer") }
        }
    }
}
