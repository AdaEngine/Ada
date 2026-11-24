@testable import AdaScene
import Math
import Testing

@Suite
struct Decal3DPlacementTests {
    @Test
    func clipsAStampAcrossADeformingTriangle() {
        let bent = [Vector3(-2, 0, 0), Vector3(0, 2, 0), Vector3(2, -2, 0)]
        let straight = [Vector3(-2, 0, 0), Vector3(0, 2, 0), Vector3(2, 0, 1)]
        let footprint = DecalTriangle3D.clip(bent[0], bent[1], bent[2])
        #expect(footprint.count >= 3)
        for vertex in footprint {
            let point = vertex.position(on: bent[0], bent[1], bent[2])
            let posed = vertex.position(on: straight[0], straight[1], straight[2])
            #expect(abs(vertex.weights.x + vertex.weights.y + vertex.weights.z - 1) < 0.00001)
            #expect(abs(point.x) <= 1.00001 && abs(point.y) <= 1.00001 && abs(point.z) <= 1.00001)
            #expect(abs(posed.z - vertex.weights.z) < 0.00001)
            #expect(abs(vertex.uv.x - (point.x + 1) / 2) < 0.00001)
            #expect(abs(vertex.uv.y - (1 - point.y) / 2) < 0.00001)
        }
        #expect(footprint.contains { $0.position(on: straight[0], straight[1], straight[2]).z > 0.1 })
    }

    @Test
    func rejectsTrianglesOutsideTheProjectorAndEdgeOnlyContact() {
        #expect(DecalTriangle3D.clip([-1, -1, 1.1], [1, -1, 1.1], [0, 1, 1.1]).isEmpty)
        #expect(DecalTriangle3D.clip([1, -1, 0], [2, -1, 0], [1, 1, 0]).isEmpty)
    }

    @Test
    func keepsSmallTrianglesInsideALargeStamp() {
        let footprint = DecalTriangle3D.clip([0, 0, 0], [0.0005, 0, 0], [0, 0.0005, 0])
        #expect(footprint.count == 3)
    }
}
