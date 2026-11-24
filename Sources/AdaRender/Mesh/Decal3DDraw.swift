/// Render buffers are scoped to the exact source geometry and receiving entity.
package struct Decal3DPartKey: Hashable, Sendable {
    let vertices: ObjectIdentifier
    let indices: ObjectIdentifier
    let indexCount: Int
    let vertexRevision: UInt64?
    let indexRevision: UInt64?

    package init(_ part: Mesh.Part) {
        self.init(vertices: part.vertexBuffer, indices: part.indexBuffer, count: part.indexCount)
    }

    init(vertices: any VertexBuffer, indices: any IndexBuffer, count: Int) {
        self.vertices = ObjectIdentifier(vertices)
        self.indices = ObjectIdentifier(indices)
        indexCount = count
        vertexRevision = vertices.geometryWriteRevision
        indexRevision = indices.geometryWriteRevision
    }

    var isTracked: Bool { vertexRevision != nil && indexRevision != nil }
}

package struct Decal3DDraw: Sendable {
    package let source: Decal3DPartKey
    package let vertices: any VertexBuffer
    package let projection: Texture2D
    package let atlas: Texture2D

    package init(source: Decal3DPartKey, vertices: any VertexBuffer, projection: Texture2D, atlas: Texture2D) {
        self.source = source
        self.vertices = vertices
        self.projection = projection
        self.atlas = atlas
    }
}
