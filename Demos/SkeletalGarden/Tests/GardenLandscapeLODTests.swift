import AdaEngine
import Foundation
import Testing

@Suite
struct GardenLandscapeLODTests {
    @Test(arguments: ["Tree", "TreeLOD1", "TreeLOD2"])
    func trunkKeepsItsSilhouetteFromEverySide(_ name: String) throws {
        let asset = try load(name)
        let trunk = try #require(asset.meshes.first?.primitives.first { $0.materialIndex == 0 })
        let vertices = try #require(trunk.attributes[.position]).vector3Values()
        let indices = try #require(trunk.indices)
        // Bounds and material slots alone allowed the old one-triangle trunk to pass.
        // Probe the actual indexed surface below the canopy from every viewing angle.
        for height: Float in [0.3, 1.3, 2.5] {
            for step in 0..<16 {
                let angle = Float(step) * .pi / 8
                let direction = Vector3(Math.cos(angle), 0, Math.sin(angle))
                let origin = Vector3(0, height, 0) + direction * 2
                let hits = stride(from: 0, to: indices.count, by: 3).contains { offset in
                    intersects(
                        origin: origin,
                        direction: -direction,
                        a: vertices[Int(indices[offset])],
                        b: vertices[Int(indices[offset + 1])],
                        c: vertices[Int(indices[offset + 2])]
                    )
                }
                #expect(hits, "\(name) has a hole in the trunk at height \(height), angle \(step)")
            }
        }
    }

    @Test
    func alternativesKeepNodeTransformsMaterialSlotsAndReduceTriangles() throws {
        let base = try load("Tree")
        let baseMesh = try #require(base.meshes.first)
        let baseTriangles = baseMesh.primitives.reduce(0) { $0 + ($1.indices?.count ?? 0) / 3 }
        var previousTriangles = baseTriangles
        for level in 1...2 {
            let lod = try load("TreeLOD\(level)")
            let mesh = try #require(lod.meshes.first)
            #expect(lod.nodes.count == base.nodes.count)
            for (a, b) in zip(base.nodes, lod.nodes) {
                #expect(a.transform == b.transform)
                #expect(a.meshIndex == b.meshIndex)
            }
            let slots = mesh.primitives.map { $0.materialIndex ?? -1 }.sorted()
            let baseSlots = baseMesh.primitives.map { $0.materialIndex ?? -1 }.sorted()
            #expect(slots == baseSlots)
            let triangles = mesh.primitives.reduce(0) { $0 + ($1.indices?.count ?? 0) / 3 }
            #expect(triangles < previousTriangles)
            previousTriangles = triangles
        }
    }

    @Test(arguments: ["Tree", "TreeLOD1", "TreeLOD2"])
    func canopyKeepsClosedSurfaces(_ name: String) throws {
        let asset = try load(name)
        let mesh = try #require(asset.meshes.first)
        var edges: [String: Int] = [:]
        for primitive in mesh.primitives where primitive.materialIndex != 0 {
            let positions = try #require(primitive.attributes[.position]).vector3Values()
            let indices = try #require(primitive.indices)
            for offset in stride(from: 0, to: indices.count, by: 3) {
                for side in 0..<3 {
                    let a = vertexKey(positions[Int(indices[offset + side])])
                    let b = vertexKey(positions[Int(indices[offset + (side + 1) % 3])])
                    let key = a < b ? "\(a)|\(b)" : "\(b)|\(a)"
                    edges[key, default: 0] += 1
                }
            }
        }
        #expect(!edges.isEmpty)
        #expect(edges.values.allSatisfy { $0 == 2 }, "\(name) canopy contains an open or collapsed surface")
    }

    private func vertexKey(_ vertex: Vector3) -> String {
        // Faceted normals duplicate vertices; weld only their geometric positions.
        "\(Int((vertex.x * 10_000).rounded())),\(Int((vertex.y * 10_000).rounded())),\(Int((vertex.z * 10_000).rounded()))"
    }

    private func load(_ name: String) throws -> GLTFImportResult {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets")
        return try NativeGLTFLoader().load(data: Data(contentsOf: directory.appendingPathComponent("\(name).glb")))
    }

    private func intersects(origin: Vector3, direction: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Bool {
        let edge1 = b - a, edge2 = c - a
        let p = direction.cross(edge2)
        let determinant = edge1.dot(p)
        guard abs(determinant) > 0.000001 else {
            return false
        }
        let t = origin - a
        let u = t.dot(p) / determinant
        let q = t.cross(edge1)
        let v = direction.dot(q) / determinant
        return u >= -0.00001 && v >= -0.00001 && u + v <= 1.00001 && edge2.dot(q) / determinant > 0
    }
}
