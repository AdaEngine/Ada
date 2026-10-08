//
//  Quad.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/20/23.
//

import Math

public struct Quad: GeometryShape {
    public let size: Vector2

    public init(size: Vector2 = .one) {
        self.size = size
    }

    public func meshDescriptors() -> [MeshDescriptor] {
        let extentX = size.x / 2
        let extentY = size.y / 2

        var mesh = MeshDescriptor(name: "Quad")
        mesh.primitiveTopology = .triangleList

        mesh.indicies = [0, 1, 2, 2, 3, 0]
        mesh.positions = [
            [-extentX, -extentY, 0.0],
            [extentX, -extentY, 0.0],
            [extentX, extentY, 0.0],
            [-extentX, extentY, 0.0],
        ]
        mesh.normals = [
            [0, 0, 1],
            [0, 0, 1],
            [0, 0, 1],
            [0, 0, 1],
        ]
        mesh.textureCoordinates = [
            [0, 1], [1, 1], [1, 0], [0, 0],
        ]

        return [mesh]
    }
}
