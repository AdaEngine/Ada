//
//  Mesh3DComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaAssets
import AdaECS
import AdaRender

/// A component that renders a 3D mesh.
public struct Mesh3DComponent: Component {
    public var mesh: Mesh
    public var materials: [Material]
    public var castShadows: Bool
    public var receiveShadows: Bool

    public init(mesh: Mesh, materials: [Material]) {
        self.init(mesh: mesh, materials: materials, castShadows: true, receiveShadows: true)
    }

    public init(mesh: Mesh, materials: [Material], castShadows: Bool, receiveShadows: Bool) {
        self.mesh = mesh
        self.materials = materials
        self.castShadows = castShadows
        self.receiveShadows = receiveShadows
    }
}
