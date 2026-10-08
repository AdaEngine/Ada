//
//  Mesh+Primitives.swift
//  AdaEngine
//

import Math

extension Mesh {
    /// Generates a cube with separate vertices and outward normals for each face.
    public static func generateCube(size: Vector3 = .one, renderDevice: RenderDevice) -> Mesh {
        precondition(size.x > 0 && size.y > 0 && size.z > 0)
        let faces: [(Vector3, Vector3, Vector3)] = [
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]),
            ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, -1]),
            ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]),
            ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
        ]
        let corners: [Vector2] = [[-1, -1], [1, -1], [1, 1], [-1, 1]]
        var positions: [Vector3] = []
        var normals: [Vector3] = []
        var uvs: [Vector2] = []
        var indices: [UInt32] = []
        for (normal, horizontal, vertical) in faces {
            let start = UInt32(positions.count)
            for corner in corners {
                let point = normal + horizontal * corner.x + vertical * corner.y
                positions.append(Vector3(point.x * size.x / 2, point.y * size.y / 2, point.z * size.z / 2))
                normals.append(normal)
                uvs.append(Vector2((corner.x + 1) / 2, (1 - corner.y) / 2))
            }
            indices += [start, start + 1, start + 2, start + 2, start + 3, start]
        }
        var descriptor = MeshDescriptor(name: "Cube")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.indicies = indices
        return generate(from: [descriptor], renderDevice: renderDevice)
    }

    /// Generates a filled circle in the XY plane facing positive Z.
    public static func generateCircle(radius: Float = 0.5, segments: Int = 64, renderDevice: RenderDevice) -> Mesh {
        precondition(radius > 0 && segments >= 3)
        var positions: [Vector3] = [.zero]
        var uvs: [Vector2] = [[0.5, 0.5]]
        var indices: [UInt32] = []
        for index in 0...segments {
            let angle = Float(index) / Float(segments) * 2 * Float.pi
            let x = Math.cos(angle)
            let y = Math.sin(angle)
            positions.append(Vector3(x * radius, y * radius, 0))
            uvs.append(Vector2((x + 1) / 2, (1 - y) / 2))
            if index < segments {
                indices += [0, UInt32(index + 1), UInt32(index + 2)]
            }
        }
        var descriptor = MeshDescriptor(name: "Circle")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(Array(repeating: Vector3(0, 0, 1), count: positions.count))
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.indicies = indices
        return generate(from: [descriptor], renderDevice: renderDevice)
    }

    /// Generates a horizontal plane facing positive Y.
    public static func generatePlane(size: Vector2 = .one, renderDevice: RenderDevice) -> Mesh {
        precondition(size.x > 0 && size.y > 0)
        let x = size.x / 2
        let z = size.y / 2
        var descriptor = MeshDescriptor(name: "Plane")
        descriptor.positions = [[-x, 0, -z], [-x, 0, z], [x, 0, z], [x, 0, -z]]
        descriptor.normals = [[0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 1, 0]]
        descriptor.textureCoordinates = [[0, 1], [1, 1], [1, 0], [0, 0]]
        descriptor.indicies = [0, 1, 2, 2, 3, 0]
        return generate(from: [descriptor], renderDevice: renderDevice)
    }

    /// Generates a UV sphere suitable for lit and textured 3D materials.
    public static func generateSphere(
        radius: Float = 0.5,
        segments: Int = 32,
        rings: Int = 20,
        renderDevice: RenderDevice
    ) -> Mesh {
        precondition(radius > 0, "Sphere radius must be greater than zero")
        precondition(segments >= 3, "A sphere requires at least three segments")
        precondition(rings >= 2, "A sphere requires at least two rings")

        var descriptor = MeshDescriptor(name: "Sphere")
        var positions: [Vector3] = []
        var normals: [Vector3] = []
        var textureCoordinates: [Vector2] = []
        var indices: [UInt32] = []

        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let theta = v * .pi
            let y = Math.cos(theta)
            let ringRadius = Math.sin(theta)
            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let phi = u * .pi * 2
                let normal = Vector3(
                    x: ringRadius * Math.cos(phi),
                    y: y,
                    z: ringRadius * Math.sin(phi)
                )
                positions.append(normal * radius)
                normals.append(normal)
                textureCoordinates.append([u, v])
            }
        }

        let stride = segments + 1
        for ring in 0..<rings {
            for segment in 0..<segments {
                let current = UInt32(ring * stride + segment)
                let next = UInt32((ring + 1) * stride + segment)
                indices.append(contentsOf: [
                    current, current + 1, next,
                    current + 1, next + 1, next,
                ])
            }
        }

        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(textureCoordinates)
        descriptor.indicies = indices
        return Self.generate(from: [descriptor], renderDevice: renderDevice)
    }
}
