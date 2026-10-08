@testable import AdaPlatform
@testable import AdaUI
import Math
import Testing

@MainActor
struct VectorPolygonClippingTests {
    init() async throws {
        try Application.prepareForTest()
    }

    private let diamond: [Vector2] = [[0, -1], [1, 0], [0, 1], [-1, 0]]

    @Test(arguments: [false, true])
    func containedPolygonPreservesVertices(clockwise: Bool) {
        let polygon: [Vector2] = [[-0.2, -0.2], [0.2, -0.2], [0.2, 0.2], [-0.2, 0.2]]
        let clip = clockwise ? Array(diamond.reversed()) : diamond
        #expect(UITessellator().clipPolygons([polygon], to: [clip]) == [polygon])
    }

    @Test(arguments: [false, true])
    func overlappingBoundsDoNotBypassRotatedMask(clockwise: Bool) {
        let polygon: [Vector2] = [[0.7, 0.7], [0.9, 0.7], [0.9, 0.9], [0.7, 0.9]]
        let clip = clockwise ? Array(diamond.reversed()) : diamond
        #expect(UITessellator().clipPolygons([polygon], to: [clip]).isEmpty)
    }

    @Test(arguments: [false, true])
    func crossingPolygonHasExpectedClippedArea(clockwise: Bool) throws {
        let polygon: [Vector2] = [[-2, -0.5], [2, -0.5], [2, 0.5], [-2, 0.5]]
        let clip = clockwise ? Array(diamond.reversed()) : diamond
        let result = try #require(UITessellator().clipPolygons([polygon], to: [clip]).first)
        #expect(result.count == 6)
        #expect(abs(area(result) - 1.5) < 0.0001)
        #expect(result.allSatisfy { abs($0.x) + abs($0.y) <= 1.0001 })
    }

    @Test
    func clippingRetainsExistingToleranceAtBoundary() {
        let clip: [Vector2] = [[0, 0], [1, 0], [1, 1], [0, 1]]
        let polygon: [Vector2] = [[1.00001, 0.2], [1.00002, 0.2], [1.00002, 0.8], [1.00001, 0.8]]
        #expect(UITessellator().clipPolygons([polygon], to: [clip]) == [polygon])
    }

    @Test
    func multipleClipPolygonsPreserveSeparatePieces() {
        let polygon: [Vector2] = [[-4, -2], [4, -2], [4, 2], [-4, 2]]
        let shifted = diamond.map { $0 + Vector2(3, 0) }
        let result = UITessellator().clipPolygons([polygon], to: [diamond, shifted])
        #expect(result.count == 2)
        #expect(abs(result.reduce(Float(0)) { $0 + area($1) } - 4) < 0.0001)
    }

    private func area(_ polygon: [Vector2]) -> Float {
        let sum = polygon.indices.reduce(Float(0)) { total, index in
            let point = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            return total + point.x * next.y - point.y * next.x
        }
        return abs(sum) / 2
    }
}
