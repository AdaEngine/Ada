@_spi(AdaEngine) import AdaEngine

/// Adds automatic roles without renumbering or removing imported layers.
enum EditorTerrainAutoPalette {
    static func make(existing: TerrainMaterialPalette?, variation: TerrainTextureVariation, addRules: Bool) -> TerrainMaterialPalette {
        var layers = (existing?.layers ?? []).map { layer in
            TerrainLayerReference(
                id: layer.id,
                name: layer.name,
                albedoPath: layer.albedoPath,
                normalPath: layer.normalPath,
                ormPath: layer.ormPath,
                blendHeightPath: layer.blendHeightPath,
                scale: layer.scale,
                tint: layer.tint,
                roughness: layer.roughness,
                metallic: layer.metallic,
                projection: layer.projection,
                variation: variation
            )
        }
        guard addRules || existing == nil else {
            return .init(
                layers: layers,
                fallbackLayerID: existing?.fallbackLayerID ?? 0,
                interiorLayerID: existing?.interiorLayerID,
                rules: existing?.rules ?? []
            )
        }
        func role(_ name: String, tint: Vector4) -> UInt16 {
            if let layer = layers.first(where: { $0.name == name }) {
                return layer.id
            }
            let used = Set(layers.map(\.id))
            guard layers.count < 32, let id = (UInt16(0)...UInt16(31)).first(where: { !used.contains($0) }) else {
                return layers.first?.id ?? 0
            }
            layers.append(.init(id: id, name: name, scale: 4, tint: tint, projection: .triplanar, variation: variation))
            return id
        }
        let grass = role("Grass", tint: [0.22, 0.42, 0.13, 1])
        let rock = role("Rock", tint: [0.45, 0.43, 0.4, 1])
        let snow = role("Snow", tint: [0.92, 0.95, 1, 1])
        let automatic = Set([grass, rock, snow])
        let rules = (existing?.rules ?? []).filter { !automatic.contains($0.layerID) } + [
            TerrainMaterialRule(layerID: grass, height: .init(minimum: -10_000, maximum: 8, transition: 4), slope: .init(minimum: 0, maximum: 35, transition: 15)),
            .init(layerID: rock, slope: .init(minimum: 35, maximum: 90, transition: 15)),
            .init(layerID: snow, height: .init(minimum: 12, maximum: 10_000, transition: 4)),
        ]
        return .init(layers: layers, fallbackLayerID: grass, interiorLayerID: rock, rules: rules)
    }
}
