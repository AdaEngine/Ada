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
    public var indirectArgumentOffset: Int?
    /// Main-pass-only cluster geometry; motion/shadow/contact draws retain the source part.
    public var meshletOverride: MeshletDrawOverride?
    /// Explicit force-visible meshes bypass cluster rejection too.
    public var forceVisible: Bool = false

    public let modelIndex: Int
    public let partIndex: Int
    public let mesh: Mesh
    public let material: Material
    public let worldTransform: Transform3D
    public let castShadows: Bool
    public let receiveShadows: Bool
    public let skinningBuffer: (any UniformBuffer)?
    /// Weights of the active morph targets, for a part with ``Mesh/Part/morphTargets``.
    public let morphBuffer: (any UniformBuffer)?

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
        batchRange: Range<Int32>? = nil,
        skinningBuffer: (any UniformBuffer)? = nil,
        morphBuffer: (any UniformBuffer)? = nil
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
        self.skinningBuffer = skinningBuffer
        self.morphBuffer = morphBuffer
    }
}

/// One frame/view's typed geometry override. Missing indirect support restores the complete source draw.
public struct MeshletDrawOverride: Sendable {
    public let indices: any IndexBuffer
    public let arguments: (any Buffer)?
    public let argumentOffset: Int
    public let ranges: [Range<Int>]

    public init(indices: any IndexBuffer, arguments: (any Buffer)? = nil, argumentOffset: Int = 0, ranges: [Range<Int>] = []) {
        self.indices = indices
        self.arguments = arguments
        self.argumentOffset = argumentOffset
        self.ranges = ranges
    }
}
