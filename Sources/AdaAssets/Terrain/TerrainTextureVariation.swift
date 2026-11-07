/// Terrain-local texture randomization. Disabled by default to preserve existing authored appearances.
public struct TerrainTextureVariation: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let seed: UInt64
    public let flipU: Bool
    public let flipV: Bool
    public let quarterTurns: Bool
    public let randomOffset: Bool
    /// Texture repetitions per variation cell; adjacent randomized samples blend across cells.
    public let cellScale: Float
    public let macroStrength: Float
    /// Terrain-local units per low-frequency macro cell.
    public let macroScale: Float

    public init(
        isEnabled: Bool = false,
        seed: UInt64 = 0,
        flipU: Bool = true,
        flipV: Bool = true,
        quarterTurns: Bool = true,
        randomOffset: Bool = true,
        cellScale: Float = 2,
        macroStrength: Float = 0.1,
        macroScale: Float = 32
    ) {
        self.isEnabled = isEnabled
        self.seed = seed
        self.flipU = flipU
        self.flipV = flipV
        self.quarterTurns = quarterTurns
        self.randomOffset = randomOffset
        self.cellScale = cellScale
        self.macroStrength = macroStrength
        self.macroScale = macroScale
    }

    private enum CodingKeys: CodingKey { case isEnabled, seed, flipU, flipV, quarterTurns, randomOffset, cellScale, macroStrength, macroScale }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            seed: try container.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0,
            flipU: try container.decodeIfPresent(Bool.self, forKey: .flipU) ?? true,
            flipV: try container.decodeIfPresent(Bool.self, forKey: .flipV) ?? true,
            quarterTurns: try container.decodeIfPresent(Bool.self, forKey: .quarterTurns) ?? true,
            randomOffset: try container.decodeIfPresent(Bool.self, forKey: .randomOffset) ?? true,
            cellScale: try container.decodeIfPresent(Float.self, forKey: .cellScale) ?? 2,
            macroStrength: try container.decodeIfPresent(Float.self, forKey: .macroStrength) ?? 0.1,
            macroScale: try container.decodeIfPresent(Float.self, forKey: .macroScale) ?? 32
        )
    }

    func validate() throws {
        guard cellScale.isFinite, (0.25...64).contains(cellScale), macroStrength.isFinite, (0...1).contains(macroStrength), macroScale.isFinite, macroScale > 0 else {
            throw TerrainManifestError.malformed("invalid terrain texture variation")
        }
    }
}
