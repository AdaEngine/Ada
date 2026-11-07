import box3d

/// Owns one immutable BVH. Box3D only borrows const mesh data; both Shape3DResource and
/// Body3D retain this owner until every native shape is destroyed. The resource cache is locked.
/// Sendable is safe because the C mesh is immutable after creation and ARC owns its allocation;
/// b3DestroyMesh only frees that allocation after the last owner releases it.
@unsafe
final class NativeTriangleMesh3D: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<b3MeshData>

    init?(_ mesh: Shape3DResource.TriangleMeshShape, metrics: PhysicsCollisionPreparationMetrics? = nil) {
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
        metrics?.recordTriangleMesh(triangleCount: mesh.indices.count / 3)
    }

    deinit { unsafe b3DestroyMesh(pointer) }
}
