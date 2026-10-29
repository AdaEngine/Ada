//
//  Mesh3DComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaAssets
import AdaECS
import AdaRender
import AdaUtils

/// A component that renders a 3D mesh.
public struct Mesh3DComponent: Component {
    public var mesh: Mesh { didSet { extractionRevision = RID() } }
    public var materials: [Material] {
        didSet {
            extractionRevision = RID()
            materialRevision = extractionRevision
        }
    }
    public var castShadows: Bool { didSet { extractionRevision = RID() } }
    public var receiveShadows: Bool { didSet { extractionRevision = RID() } }

    // Copies retain their revision; replacing or editing any source field invalidates extraction.
    private(set) var extractionRevision = RID()
    private(set) var materialRevision = RID()

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
