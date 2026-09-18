//
//  RenderPipeline.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/8/23.
//

import AdaUtils
import Math

/// An object that contains graphics functions and configuration state to use in a render command.
public protocol RenderPipeline: AnyObject, Sendable {
    /// /// Contains information about render pipeline descriptor.
    var descriptor: RenderPipelineDescriptor { get }
}

/// An object that defines the front-facing or back-facing stencil operations of a depth and stencil state object.
public struct StencilOperationDescriptor: Sendable {
    /// The operation that is performed to update the values in the stencil attachment when the stencil test fails.
    public var fail: StencilOperation

    /// The operation that is performed to update the values in the stencil attachment when both the stencil test and the depth test pass.
    public var pass: StencilOperation

    /// The operation that is performed to update the values in the stencil attachment when the stencil test passes, but the depth test fails.
    public var depthFail: StencilOperation

    /// The comparison that is performed between the masked reference value and a masked value in the stencil attachment.
    public var compare: CompareOperation

    /// A bitmask that determines to which bits that stencil operations can write.
    public var writeMask: UInt32

    /// Initialize a new stencil operation descriptor.
    ///
    /// - Parameter fail: The operation that is performed to update the values in the stencil attachment when the stencil test fails.
    /// - Parameter pass: The operation that is performed to update the values in the stencil attachment when both the stencil test and the depth test pass.
    /// - Parameter depthFail: The operation that is performed to update the values in the stencil attachment when the stencil test passes, but the depth test fails.
    /// - Parameter compare: The comparison that is performed between the masked reference value and a masked value in the stencil attachment.
    /// - Parameter writeMask: A bitmask that determines to which bits that stencil operations can write.
    public init(
        fail: StencilOperation = .zero,
        pass: StencilOperation = .zero,
        depthFail: StencilOperation = .zero,
        compare: CompareOperation = .always,
        writeMask: UInt32 = 0
    ) {
        self.fail = fail
        self.pass = pass
        self.depthFail = depthFail
        self.compare = compare
        self.writeMask = writeMask
    }
}

/// An object that configures new depth and stencil operation.
public struct DepthStencilDescriptor: Sendable {
    /// A Boolean value that indicates whether depth testing is enabled.
    public var isDepthTestEnabled: Bool

    /// A Boolean value that indicates whether depth values can be written to the depth attachment.
    public var isDepthWriteEnabled: Bool

    /// The comparison that is performed between a fragment’s depth value and the depth value in the attachment, which determines whether to discard the fragment.
    ///
    /// - SeeAlso: ``CompareOperation``
    public var depthCompareOperator: CompareOperation

    /// A Boolean value that indicates whether depth range is enabled.
    public var isDepthRangeEnabled: Bool

    /// The minimum depth value.
    public var depthRangeMin: Float

    /// The maximum depth value.
    public var depthRangeMax: Float

    /// A Boolean value that indicates whether stencil testing is enabled.
    public var isEnableStencil: Bool

    /// The stencil operation descriptor.
    public var stencilOperationDescriptor: StencilOperationDescriptor?

    /// Initialize a new depth stencil descriptor.
    ///
    /// - Parameter isDepthTestEnabled: A Boolean value that indicates whether depth testing is enabled.
    /// - Parameter isDepthWriteEnabled: A Boolean value that indicates whether depth values can be written to the depth attachment.
    /// - Parameter depthCompareOperator: The comparison between a fragment’s depth value and the
    ///   attachment depth value that determines whether to discard the fragment.
    /// - Parameter isDepthRangeEnabled: A Boolean value that indicates whether depth range is enabled.
    /// - Parameter depthRangeMin: The minimum depth value.
    /// - Parameter depthRangeMax: The maximum depth value.
    public init(
        isDepthTestEnabled: Bool = true,
        isDepthWriteEnabled: Bool = true,
        depthCompareOperator: CompareOperation = .greaterOrEqual,
        isDepthRangeEnabled: Bool = false,
        depthRangeMin: Float = 0,
        depthRangeMax: Float = 0,
        isEnableStencil: Bool = false,
        stencilOperationDescriptor: StencilOperationDescriptor? = nil
    ) {
        self.isDepthTestEnabled = isDepthTestEnabled
        self.isDepthWriteEnabled = isDepthWriteEnabled
        self.depthCompareOperator = depthCompareOperator
        self.isDepthRangeEnabled = isDepthRangeEnabled
        self.depthRangeMin = depthRangeMin
        self.depthRangeMax = depthRangeMax
        self.isEnableStencil = isEnableStencil
        self.stencilOperationDescriptor = stencilOperationDescriptor
    }
}

/// An object that specifies the format and properties of a color attachment.
public struct RenderPipelineColorAttachmentDescriptor: Sendable {
    /// The format of the color attachment.
    public var format: PixelFormat

    /// A Boolean value that indicates whether blending is enabled.
    public var isBlendingEnabled: Bool = false

    /// The source RGB blend factor.
    public var sourceRGBBlendFactor: BlendFactor

    /// The source alpha blend factor.
    public var sourceAlphaBlendFactor: BlendFactor

    /// The RGB blend operation.
    public var rgbBlendOperation: BlendOperation

    /// The alpha blend operation.
    public var alphaBlendOperation: BlendOperation

    /// The destination alpha blend factor.
    public var destinationAlphaBlendFactor: BlendFactor

    /// The destination RGB blend factor.
    public var destinationRGBBlendFactor: BlendFactor

    /// Initialize a new color attachment descriptor.
    ///
    /// - Parameter format: The format of the color attachment.
    /// - Parameter isBlendingEnabled: A Boolean value that indicates whether blending is enabled.
    /// - Parameter sourceRGBBlendFactor: The source RGB blend factor.
    /// - Parameter sourceAlphaBlendFactor: The source alpha blend factor.
    public init(
        format: PixelFormat,
        isBlendingEnabled: Bool = false,
        sourceRGBBlendFactor: BlendFactor = .sourceAlpha,
        sourceAlphaBlendFactor: BlendFactor = .one,
        rgbBlendOperation: BlendOperation = .add,
        alphaBlendOperation: BlendOperation = .add,
        destinationAlphaBlendFactor: BlendFactor = .oneMinusSourceAlpha,
        destinationRGBBlendFactor: BlendFactor = .oneMinusSourceAlpha
    ) {
        self.format = format
        self.isBlendingEnabled = isBlendingEnabled
        self.sourceRGBBlendFactor = sourceRGBBlendFactor
        self.sourceAlphaBlendFactor = sourceAlphaBlendFactor
        self.rgbBlendOperation = rgbBlendOperation
        self.alphaBlendOperation = alphaBlendOperation
        self.destinationAlphaBlendFactor = destinationAlphaBlendFactor
        self.destinationRGBBlendFactor = destinationRGBBlendFactor
    }
}

/// An object that describes the depth and stencil attachment configuration for a render pass.
public struct DepthStencilAttachmentDescriptor: Sendable {
    /// The texture to use as the depth and stencil attachment target.
    public var texture: Texture

    /// The depth operation descriptor.
    public var depthOperation: OperationDescriptor?

    /// The stencil operation descriptor.
    public var stencilOperation: OperationDescriptor?

    /// Initialize a new depth stencil attachment descriptor.
    ///
    /// - Parameter texture: The texture to use as the depth and stencil attachment target.
    /// - Parameter depthOperation: The depth operation descriptor.
    /// - Parameter stencilOperation: The stencil operation descriptor.
    public init(
        texture: Texture,
        depthOperation: OperationDescriptor? = nil,
        stencilOperation: OperationDescriptor? = nil
    ) {
        self.texture = texture
        self.depthOperation = depthOperation
        self.stencilOperation = stencilOperation
    }
}

/// An object that describes the load and store operations for an attachment.
public struct OperationDescriptor: Sendable {
    /// The load action for the operation.
    public var loadAction: AttachmentLoadAction

    /// The store action for the operation.
    public var storeAction: AttachmentStoreAction

    /// Initialize a new operation descriptor.
    ///
    /// - Parameter loadAction: The load action for the operation.
    /// - Parameter storeAction: The store action for the operation.
    public init(
        loadAction: AttachmentLoadAction,
        storeAction: AttachmentStoreAction
    ) {
        self.loadAction = loadAction
        self.storeAction = storeAction
    }
}

/// An object specifies the rendering configuration state to use during a rendering pass,
/// including rasterization (such as multisampling), visibility, blending, tessellation, and graphics function state.
///
/// To specify the vertex or fragment function in the rendering pipeline descriptor, set the vertex or fragment property.
public struct RenderPipelineDescriptor: Sendable {
    /// The vertex shader the pipeline run to process vertices.
    public var vertex: Shader

    /// The fragment shader the pipeline run to process fragments.
    public var fragment: Shader?

    /// A string that identifies the render pipeline descriptor.
    public var debugName: String = ""

    /// A Boolean value that indicates whether backface culling is enabled.
    public var backfaceCulling: Bool = true

    /// The primitive type.
    public var primitive: IndexPrimitive = .triangle

    /// The organization of vertex data in an attribute’s argument table.
    public var vertexDescriptor: VertexDescriptor = VertexDescriptor()

    /// The depth stencil descriptor.
    public var depthStencilDescriptor: DepthStencilDescriptor?

    /// The depth pixel format.
    public var depthPixelFormat: PixelFormat = .depth_32f_stencil8

    /// The color attachments.
    public var colorAttachments: [RenderPipelineColorAttachmentDescriptor] = []

    /// Initialize a new render pipeline descriptor.
    ///
    /// - Parameter vertex: The vertex shader.
    /// - Parameter fragment: The fragment shader.
    /// - Parameter debugName: A string that identifies the render pipeline descriptor.
    /// - Parameter backfaceCulling: A Boolean value that indicates whether backface culling is enabled.
    public init(
        vertex: Shader,
        fragment: Shader? = nil,
        debugName: String = "",
        backfaceCulling: Bool = true,
        primitive: IndexPrimitive = .triangle,
        vertexDescriptor: VertexDescriptor = VertexDescriptor(),
        depthStencilDescriptor: DepthStencilDescriptor? = nil,
        depthPixelFormat: PixelFormat = .depth_32f_stencil8,
        colorAttachments: [RenderPipelineColorAttachmentDescriptor] = []
    ) {
        self.vertex = vertex
        self.fragment = fragment
        self.debugName = debugName
        self.backfaceCulling = backfaceCulling
        self.primitive = primitive
        self.vertexDescriptor = vertexDescriptor
        self.depthStencilDescriptor = depthStencilDescriptor
        self.depthPixelFormat = depthPixelFormat
        self.colorAttachments = colorAttachments
    }
}
