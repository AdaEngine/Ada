//
//  Opaque3DRenderItem.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaECS
import Math

public struct Opaque3DRenderItem: RenderItem {
    public let entity: Entity.ID
    public let drawPass: any DrawPass
    public let sortKey: Float
    public var batchRange: Range<Int32>?

    public let modelIndex: Int
    public let partIndex: Int
    public let mesh: Mesh
    public let material: Material
    public let worldTransform: Transform3D
    public let castShadows: Bool
    public let receiveShadows: Bool

    public init(
        entity: Entity.ID,
        drawPass: any DrawPass,
        sortKey: Float,
        modelIndex: Int,
        partIndex: Int,
        mesh: Mesh,
        material: Material,
        worldTransform: Transform3D,
        castShadows: Bool = true,
        receiveShadows: Bool = true,
        batchRange: Range<Int32>? = nil
    ) {
        self.entity = entity
        self.drawPass = drawPass
        self.sortKey = sortKey
        self.modelIndex = modelIndex
        self.partIndex = partIndex
        self.mesh = mesh
        self.material = material
        self.worldTransform = worldTransform
        self.castShadows = castShadows
        self.receiveShadows = receiveShadows
        self.batchRange = batchRange
    }
}
