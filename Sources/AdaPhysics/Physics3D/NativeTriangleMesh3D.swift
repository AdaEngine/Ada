import box3d

/// Box3D borrows this immutable BVH. Body3D retains it until after its native body is destroyed.
/// Creation/destruction follows the same serialized physics lifetime as Body3D.
@unsafe
final class NativeTriangleMesh3D {
    let pointer: UnsafeMutablePointer<b3MeshData>

    init?(_ mesh: Shape3DResource.TriangleMeshShape) {
        var vertices = mesh.vertices.map(\.b3Vec)
        var indices = mesh.indices.map { Int32($0) }
        let data = unsafe vertices.withUnsafeMutableBufferPointer { points in
            unsafe indices.withUnsafeMutableBufferPointer { triangles in
                var definition = b3MeshDef()
                unsafe definition.vertices = points.baseAddress
                unsafe definition.indices = triangles.baseAddress
                definition.vertexCount = Int32(points.count)
                definition.triangleCount = Int32(triangles.count / 3)
                definition.identifyEdges = true
                definition.useMedianSplit = true
                return unsafe b3CreateMesh(&definition, nil, 0)
            }
        }
        guard let data = unsafe data else {
            return nil
        }
        unsafe pointer = data
    }

    deinit { unsafe b3DestroyMesh(pointer) }
}
