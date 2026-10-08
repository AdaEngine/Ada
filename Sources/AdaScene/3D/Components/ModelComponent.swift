//
//  ModelComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/1/21.
//

import AdaRender

public struct ModelComponent {
    public var mesh: Mesh

    public init(mesh: Mesh) {
        self.mesh = mesh
    }
}
