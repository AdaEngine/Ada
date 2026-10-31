import AdaRender
import Foundation

/// A smooth display-referred curve with input and output in `0...1`.
/// Points are ordered by input; inputs within 0.0001 merge, keeping the last output. Invalid points are ignored.
public struct ColorCurve3D: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var input: Float
        public var output: Float

        public init(_ input: Float, _ output: Float) {
            self.input = input
            self.output = output
        }
    }

    public var points: [Point]

    public init(points: [Point] = [Point(0, 0), Point(1, 1)]) {
        self.points = points
    }

    /// Finite, ordered control points, with endpoints added when absent. At most 32 points are used.
    public var sanitized: Self {
        var ordered: [(index: Int, point: Point)] = []
        for (index, point) in points.enumerated() where point.input.isFinite && point.output.isFinite {
            let clamped = Point(min(max(point.input, 0), 1), min(max(point.output, 0), 1))
            ordered.append((index, clamped))
        }
        ordered.sort { $0.point.input == $1.point.input ? $0.index < $1.index : $0.point.input < $1.point.input }
        var result: [Point] = []
        for item in ordered {
            if let previous = result.last, item.point.input - previous.input < 0.0001 {
                result[result.count - 1] = Point(item.point.input == 1 ? 1 : previous.input, item.point.output)
            } else {
                result.append(item.point)
            }
        }
        guard !result.isEmpty else { return Self() }
        if let first = result.first, first.input < 0.0001 { result[0].input = 0 }
        if let last = result.last, last.input > 0.9999 { result[result.count - 1].input = 1 }
        if result.first?.input != 0 { result.insert(Point(0, 0), at: 0) }
        if result.last?.input != 1 { result.append(Point(1, 1)) }
        if result.count > 32 { result = Array(result.prefix(31)) + [Point(1, result.last?.output ?? 1)] }
        return Self(points: result)
    }

    /// Shape-preserving cubic interpolation: smooth transitions without overshooting neighboring points.
    public func evaluate(at input: Float) -> Float {
        sanitized.evaluateSanitized(at: input)
    }

    /// Evenly spaced samples including black and white. Count is limited to `2...4096`.
    public func sampledValues(count: Int = 256) -> [Float] {
        let curve = sanitized
        let count = min(max(count, 2), 4096)
        return (0..<count).map { curve.evaluateSanitized(at: Float($0) / Float(count - 1)) }
    }

    func evaluateSanitized(at input: Float) -> Float {
        let value = input.isFinite ? min(max(input, 0), 1) : 0
        guard let first = points.first, let last = points.last else { return value }
        if value <= first.input { return first.output }
        if value >= last.input { return last.output }
        let upper = points.firstIndex { $0.input >= value } ?? (points.count - 1)
        let lower = upper - 1
        func slope(_ index: Int) -> Float {
            (points[index + 1].output - points[index].output) / (points[index + 1].input - points[index].input)
        }
        func tangent(_ index: Int) -> Float {
            if index == 0 { return slope(0) }
            if index == points.count - 1 { return slope(index - 1) }
            let left = slope(index - 1), right = slope(index)
            guard left * right > 0 else { return 0 }
            let before = points[index].input - points[index - 1].input
            let after = points[index + 1].input - points[index].input
            let weight1 = 2 * after + before, weight2 = after + 2 * before
            return (weight1 + weight2) / (weight1 / left + weight2 / right)
        }
        let width = points[upper].input - points[lower].input
        let t = (value - points[lower].input) / width
        let t2 = t * t, t3 = t2 * t
        let output = (2 * t3 - 3 * t2 + 1) * points[lower].output + (t3 - 2 * t2 + t) * width * tangent(lower)
            + (-2 * t3 + 3 * t2) * points[upper].output + (t3 - t2) * width * tangent(upper)
        return min(max(output, 0), 1)
    }
}

/// Master RGB curve followed by individual channel curves, applied after tone mapping.
public struct ColorCurves3D: Codable, Equatable, Sendable {
    public var master: ColorCurve3D
    public var red: ColorCurve3D
    public var green: ColorCurve3D
    public var blue: ColorCurve3D

    public init(master: ColorCurve3D = .init(), red: ColorCurve3D = .init(), green: ColorCurve3D = .init(), blue: ColorCurve3D = .init()) {
        self.master = master
        self.red = red
        self.green = green
        self.blue = blue
    }

    private enum CodingKeys: CodingKey { case master, red, green, blue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        master = try container.decodeIfPresent(ColorCurve3D.self, forKey: .master) ?? .init()
        red = try container.decodeIfPresent(ColorCurve3D.self, forKey: .red) ?? .init()
        green = try container.decodeIfPresent(ColorCurve3D.self, forKey: .green) ?? .init()
        blue = try container.decodeIfPresent(ColorCurve3D.self, forKey: .blue) ?? .init()
    }

    var sanitized: Self { Self(master: master.sanitized, red: red.sanitized, green: green.sanitized, blue: blue.sanitized) }

    /// Bakes the separable curves into the same strip layout as imported LUTs.
    func makeLUTImage() -> Image {
        let curves = sanitized
        let size = 32
        let samples = (0..<size).map { curves.master.evaluateSanitized(at: Float($0) / Float(size - 1)) }
        func channel(_ curve: ColorCurve3D) -> [UInt8] {
            samples.map { UInt8((curve.evaluateSanitized(at: $0) * 255).rounded()) }
        }
        let reds = channel(curves.red), greens = channel(curves.green), blues = channel(curves.blue)
        var bytes = [UInt8](repeating: 255, count: size * size * size * 4)
        for tile in 0..<size {
            for row in 0..<size {
                for column in 0..<size {
                    let offset = (row * size * size + tile * size + column) * 4
                    bytes[offset] = reds[column]
                    bytes[offset + 1] = greens[row]
                    bytes[offset + 2] = blues[tile]
                }
            }
        }
        return Image(width: size * size, height: size, data: Data(bytes), format: .rgba8)
    }
}

/// Selects the source of display-referred color correction. Other grading controls remain independent.
public enum ColorCorrectionMode3D: String, Codable, CaseIterable, Sendable {
    case disabled
    case curves
    case lut
}
