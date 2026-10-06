import Math

/// Local destination rectangles and normalized source rectangles, both in Y-up coordinates.
/// Streaming quads avoids allocating a slice array for each sprite each frame.
struct SpriteGeometry {
    let size: Vector2
    let sourceSize: Vector2
    let anchor: SpriteAnchor
    let imageMode: SpriteImageMode
    var flipX: Bool = false
    var flipY: Bool = false

    var isValid: Bool {
        size.x.isFinite && size.y.isFinite && size.x > 0 && size.y > 0
            && sourceSize.x.isFinite && sourceSize.y.isFinite && sourceSize.x > 0 && sourceSize.y > 0
            && anchor.x.isFinite && anchor.y.isFinite
            && origin.x.isFinite && origin.y.isFinite
            && (origin.x + size.x).isFinite && (origin.y + size.y).isFinite
    }

    var origin: Vector2 {
        Vector2((-0.5 - anchor.x) * size.x, (-0.5 - anchor.y) * size.y)
    }

    func forEachQuad(_ emit: (Rect, Rect) -> Void) {
        visitQuads { destination, source in
            emit(destination, source)
            return true
        }
    }

    /// Inverts exactly the rendered layout and stops when a matching quad is found.
    func sourcePoint(at point: Vector2) -> Vector2? {
        var result: Vector2?
        visitQuads { destination, source in
            guard point.x >= destination.minX, point.x < destination.maxX,
                point.y >= destination.minY, point.y < destination.maxY else {
                    return true
                }
            result = Vector2(
                source.minX + (point.x - destination.minX) / destination.size.width * source.size.width,
                source.minY + (point.y - destination.minY) / destination.size.height * source.size.height
            )
            return false
        }
        return result
    }

    private func visitQuads(_ emit: (Rect, Rect) -> Bool) {
        guard isValid else {
            return
        }
        let fullSource = Rect(x: 0, y: 0, width: 1, height: 1)
        let destination = Rect(x: origin.x, y: origin.y, width: size.x, height: size.y)
        switch imageMode {
        case .stretch:
            _ = emit(destination, fullSource)
        case .fit:
            // Compare aspect ratios without multiplying source dimensions by large scales.
            let ratio = sourceSize.x / sourceSize.y
            let fitted = size.x / size.y > ratio ? Vector2(size.y * ratio, size.y) : Vector2(size.x, size.x / ratio)
            _ = emit(Rect(
                x: origin.x + (size.x - fitted.x) * 0.5,
                y: origin.y + (size.y - fitted.y) * 0.5,
                width: fitted.x,
                height: fitted.y
            ), fullSource)
        case .fill:
            let ratio = sourceSize.x / sourceSize.y
            let coverage = size.x / size.y > ratio
                ? Vector2(1, (size.y / size.x) * ratio)
                : Vector2((size.x / size.y) / ratio, 1)
            _ = emit(destination, Rect(x: (1 - coverage.x) * 0.5, y: (1 - coverage.y) * 0.5, width: coverage.x, height: coverage.y))
        case let .sliced(border):
            sliced(border: border, emit: emit)
        case let .tiled(tileX, tileY, scale):
            tiled(tileX: tileX, tileY: tileY, scale: scale, emit: emit)
        }
    }

    private func sliced(border: SpriteSliceBorder, emit: (Rect, Rect) -> Bool) {
        guard border.top.isFinite, border.left.isFinite, border.bottom.isFinite, border.right.isFinite else {
            return
        }
        let horizontal = SliceAxis(source: sourceSize.x, destination: size.x, first: flipX ? border.right : border.left, last: flipX ? border.left : border.right)
        let vertical = SliceAxis(source: sourceSize.y, destination: size.y, first: flipY ? border.top : border.bottom, last: flipY ? border.bottom : border.top)
        for row in 0..<3 {
            for column in 0..<3 {
                let destX = horizontal.destinationInterval(column)
                let destY = vertical.destinationInterval(row)
                let srcX = horizontal.sourceInterval(column)
                let srcY = vertical.sourceInterval(row)
                guard destX.y > 0, destY.y > 0, srcX.y > 0, srcY.y > 0 else {
                    continue
                }
                if !emit(
                    Rect(x: origin.x + destX.x, y: origin.y + destY.x, width: destX.y, height: destY.y),
                    Rect(x: srcX.x, y: srcY.x, width: srcX.y, height: srcY.y)
                ) {
                    return
                }
            }
        }
    }

    private func tiled(tileX: Bool, tileY: Bool, scale: Float, emit: (Rect, Rect) -> Bool) {
        guard scale.isFinite, scale > 0 else {
            return
        }
        let tileSize = Vector2(tileX ? sourceSize.x * scale : size.x, tileY ? sourceSize.y * scale : size.y)
        guard tileSize.x.isFinite, tileSize.y.isFinite, tileSize.x > 0, tileSize.y > 0 else {
            return
        }
        let columns = max(1, (size.x / tileSize.x).rounded(.up))
        let rows = max(1, (size.y / tileSize.y).rounded(.up))
        // Check floats before converting to Int. Extremely small tiles must not hang or overflow.
        guard columns.isFinite, rows.isFinite, columns <= 16_384, rows <= 16_384, columns * rows <= 16_384 else {
            _ = emit(Rect(x: origin.x, y: origin.y, width: size.x, height: size.y), Rect(x: 0, y: 0, width: 1, height: 1))
            return
        }
        for row in 0..<Int(rows) {
            for column in 0..<Int(columns) {
                let offset = Vector2(Float(column) * tileSize.x, Float(row) * tileSize.y)
                let width = min(tileSize.x, size.x - offset.x)
                let height = min(tileSize.y, size.y - offset.y)
                guard width > 0, height > 0 else {
                    continue
                }
                if !emit(
                    Rect(x: origin.x + offset.x, y: origin.y + offset.y, width: width, height: height),
                    Rect(x: 0, y: 0, width: width / tileSize.x, height: height / tileSize.y)
                ) {
                    return
                }
            }
        }
    }
}

private struct SliceAxis {
    let source: Float
    let destination: Float
    let first: Float
    let last: Float
    let borderScale: Float

    init(source: Float, destination: Float, first: Float, last: Float) {
        self.source = source
        self.destination = destination
        // Match AdaUI's slicing contract: reserve at least one source pixel for the center.
        self.first = min(max(0, first), max(0, source - 1))
        self.last = min(max(0, last), max(0, source - self.first - 1))
        let total = self.first + self.last
        self.borderScale = total > 0 ? min(1, destination / total) : 1
    }

    func sourceInterval(_ index: Int) -> Vector2 {
        switch index {
        case 0: Vector2(0, first / source)
        case 1: Vector2(first / source, (source - first - last) / source)
        default: Vector2((source - last) / source, last / source)
        }
    }

    func destinationInterval(_ index: Int) -> Vector2 {
        switch index {
        case 0: Vector2(0, first * borderScale)
        case 1: Vector2(first * borderScale, max(0, destination - (first + last) * borderScale))
        default: Vector2(destination - last * borderScale, last * borderScale)
        }
    }
}
