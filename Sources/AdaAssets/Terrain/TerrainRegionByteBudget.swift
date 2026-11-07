extension TerrainRegionAsset {
    /// Checks the exact native01/02/03 wire size using metadata counts, without walking or copying records.
    @_spi(Internal)
    public static func validateRecordBudget(tileCount: Int, pageCount: Int, instanceCount: Int, surfaceCount: Int, ruleMaskCount: Int) throws {
        guard (0...16).contains(tileCount), (0...16).contains(pageCount), (0...maximumInstances).contains(instanceCount),
            (0...maximumSurfaceSamples).contains(surfaceCount), (0...maximumRuleMaskSamples).contains(ruleMaskCount)
        else { throw TerrainRegionError.malformed("region record count exceeds its budget") }
        guard encodedSize(tileCount: tileCount, pageCount: pageCount, instanceCount: instanceCount, surfaceCount: surfaceCount, ruleMaskCount: ruleMaskCount)
            <= (maximumEncodedBytes ?? 0)
        else { throw TerrainRegionError.malformed("encoded byte budget exceeded") }
    }

    /// Inputs are bounded by record validation before serialization or staging.
    static func encodedSize(tileCount: Int, pageCount: Int, instanceCount: Int, surfaceCount: Int, ruleMaskCount: Int) -> Int {
        if instanceCount == 0 && surfaceCount == 0 && ruleMaskCount == 0 {
            return 24 + tileCount * 4 + pageCount * 16_388
        }
        let height = tileCount == 0 && pageCount == 0 ? 0 : 8 + tileCount * 4 + pageCount * 16_388
        let sections = (height > 0 ? 1 : 0) + (instanceCount > 0 ? 1 : 0) + (surfaceCount > 0 ? 1 : 0) + (ruleMaskCount > 0 ? 1 : 0)
        return 24 + sections * 16 + height + instanceCount * 64 + surfaceCount * 64 + ruleMaskCount * 8
    }
}
