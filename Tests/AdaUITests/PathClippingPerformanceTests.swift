@testable import AdaPlatform
@testable import AdaUI
import Foundation
import Math
import Testing

@MainActor
struct PathClippingPerformanceTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_PERFORMANCE_BENCHMARK"] == "1"))
    func measurePathsInsideRoundedPanel() {
        let tessellator = UITessellator()
        let panel = RoundedRectangleShape(cornerRadius: 12).path(in: Rect(x: 0, y: 0, width: 1_000, height: 800))
        let clips = tessellator.clipPathPolygons(panel, transform: .identity)
        let path = RoundedRectangleShape(cornerRadius: 4).path(in: Rect(x: 50, y: 50, width: 80, height: 24))
        var vertexCount = 0
        let duration = ContinuousClock().measure {
            for _ in 0..<30_000 {
                vertexCount += tessellator.tessellatePathFill(path, color: .white, transform: .identity, clipPolygons: clips).vertices.count
            }
        }
        print("PERFORMANCE rounded-panel 30000 paths: \(duration); vertices: \(vertexCount)")
        #expect(vertexCount > 0)
    }
}
