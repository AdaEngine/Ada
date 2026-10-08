import Math

/// Fixed borders of a nine-slice image, measured in source pixels.
public struct ImageCapInsets: Sendable, Equatable {
    public var top: Int
    public var leading: Int
    public var bottom: Int
    public var trailing: Int

    public init(top: Int = 0, leading: Int = 0, bottom: Int = 0, trailing: Int = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(_ value: Int) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }
}

struct ImageSliceGrid {
    let x: [Int]
    let y: [Int]

    init(width: Int, height: Int, insets: ImageCapInsets) {
        // Keep at least one source pixel in the stretchable center.
        func axis(_ length: Int, _ first: Int, _ last: Int) -> [Int] {
            let first = min(max(0, first), max(0, length - 1))
            let last = min(max(0, last), max(0, length - first - 1))
            return [0, first, length - last, length]
        }
        x = axis(width, insets.leading, insets.trailing)
        y = axis(height, insets.top, insets.bottom)
    }

    func sourceRect(column: Int, row: Int) -> RectInt {
        RectInt(x: x[column], y: y[row], width: x[column + 1] - x[column], height: y[row + 1] - y[row])
    }

    func destinationRect(column: Int, row: Int, frame: Rect) -> Rect {
        func axis(_ source: [Int], _ length: Float, _ index: Int) -> (Float, Float) {
            let first = Float(source[1])
            let last = Float(source[3] - source[2])
            let length = max(0, length)
            let scale = first + last > 0 ? min(1, length / (first + last)) : 1
            let start: Float = index == 0 ? 0 : index == 1 ? first * scale : length - last * scale
            let end: Float = index == 0 ? first * scale : index == 1 ? length - last * scale : length
            return (start, max(0, end - start))
        }
        let horizontal = axis(x, frame.size.width, column)
        let vertical = axis(y, frame.size.height, row)
        return Rect(x: frame.origin.x + horizontal.0, y: frame.origin.y + vertical.0, width: horizontal.1, height: vertical.1)
    }
}
