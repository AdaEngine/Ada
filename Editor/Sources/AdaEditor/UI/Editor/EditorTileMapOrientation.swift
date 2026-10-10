@_spi(AdaEngine) import AdaEngine

extension TileOrientation {
    var editorLabel: String {
        switch self {
        case .identity: "Original"
        case .rotate90: "Rotate 90°"
        case .rotate180: "Rotate 180°"
        case .rotate270: "Rotate 270°"
        case .mirrorX: "Mirror X"
        case .mirrorXRotate90: "Mirror X + 90°"
        case .mirrorXRotate180: "Mirror X + 180°"
        case .mirrorXRotate270: "Mirror X + 270°"
        }
    }
}
