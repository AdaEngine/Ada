import AdaAssets
import Foundation
import Testing

@Suite
struct NativeOBJLoaderTests {
    @Test
    func loadsTriangle() throws {
        let result = try load(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            f 1 2 3
            """
        )

        let mesh = try #require(result.meshes.first)
        let primitive = try #require(mesh.primitives.first)
        #expect(mesh.name == "Default")
        #expect(primitive.positions.count == 3)
        #expect(primitive.indices == [0, 1, 2])
        #expect(primitive.normals == nil)
        #expect(primitive.textureCoordinates == nil)
    }

    @Test
    func triangulatesPolygonAndDeduplicatesVertices() throws {
        let result = try load(
            """
            v 0 0 0
            v 1 0 0
            v 1 1 0
            v 0 1 0
            vt 0 0
            vt 1 0
            vt 1 1
            vt 0 1
            vn 0 0 1
            f 1/1/1 2/2/1 3/3/1 4/4/1
            """
        )

        let primitive = try #require(result.meshes.first?.primitives.first)
        #expect(primitive.positions.count == 4)
        #expect(primitive.normals?.count == 4)
        #expect(primitive.textureCoordinates?.count == 4)
        #expect(primitive.indices == [0, 1, 2, 0, 2, 3])
    }

    @Test
    func supportsNegativeIndicesGroupsAndMaterials() throws {
        let result = try load(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            o Triangle
            usemtl Red
            f -3 -2 -1
            g Second
            usemtl Blue
            f 1 3 2
            """
        )

        #expect(result.meshes.map(\.name) == ["Triangle", "Second"])
        #expect(result.meshes[0].primitives[0].materialIndex == 1)
        #expect(result.meshes[1].primitives[0].materialIndex == 2)
        #expect(result.materials.map(\.name) == [nil, "Red", "Blue"])
    }

    @Test
    func rejectsOutOfBoundsIndex() {
        #expect(throws: OBJLoadingError.invalidIndex(line: 6, value: "4")) {
            try load(
                """

                # A blank line and a comment must still count toward diagnostics.
                v 0 0 0
                v 1 0 0
                v 0 1 0
                f 1 2 4
                """
            )
        }
    }

    private func load(_ source: String) throws -> OBJImportResult {
        try NativeOBJLoader().load(data: Data(source.utf8))
    }
}
