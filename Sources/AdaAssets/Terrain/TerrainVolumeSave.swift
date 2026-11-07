/// Selects complete volume cache replacement or an incremental save retaining untouched bricks.
public enum TerrainVolumeSaveMode: Sendable {
    case replaceAll
    case update(removing: [TerrainVolumeBrickReference])
}

/// Desired ordered operations and private brick snapshots for one manifest publication.
public struct TerrainVolumeSave: Sendable {
    public let document: TerrainVolumeDocumentAsset
    public let bricks: [TerrainVolumeBrickAsset]
    public let mode: TerrainVolumeSaveMode

    public init(document: TerrainVolumeDocumentAsset, bricks: [TerrainVolumeBrickAsset], mode: TerrainVolumeSaveMode = .replaceAll) {
        self.document = document; self.bricks = bricks; self.mode = mode
    }
}
