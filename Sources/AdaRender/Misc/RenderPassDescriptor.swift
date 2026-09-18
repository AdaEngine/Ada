//
//  RenderPassDescriptor.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 26.11.2025.
//

import AdaUtils
import Math

/// An object that describes the configuration of a render pass.
public struct RenderPassDescriptor: Sendable {
    /// An optional debug label for the render pass.
    ///
    /// This label appears in GPU debugging tools to help identify the pass.
    public var label: String?

    /// The color attachments for the render pass.
    ///
    /// Each attachment describes how to use a texture as a color target in the render pass.
    public var colorAttachments: [RenderPassColorAttachmentDescriptor]

    /// The depth stencil attachment for the render pass.
    ///
    /// This attachment describes how to use a texture as a depth and stencil target in the render pass.
    public var depthStencilAttachment: DepthStencilAttachmentDescriptor?

    /// Initialize a new render pass descriptor.
    ///
    /// - Parameter label: An optional debug label for the render pass.
    /// - Parameter colorAttachments: The color attachments for the render pass.
    /// - Parameter depthStencilAttachment: The depth stencil attachment for the render pass.
    public init(
        label _: String? = nil,
        colorAttachments: [RenderPassColorAttachmentDescriptor],
        depthStencilAttachment: DepthStencilAttachmentDescriptor? = nil
    ) {
        self.colorAttachments = colorAttachments
        self.depthStencilAttachment = depthStencilAttachment
    }
}

/// An object that describes a color attachment configuration for a render pass.
public struct RenderPassColorAttachmentDescriptor: Sendable {
    /// The texture to use as the color attachment target.
    public var texture: Texture

    /// An optional texture to resolve multisampled rendering into.
    ///
    /// When specified, the render pass will resolve the multisampled `texture` into this resolve texture.
    /// This is typically used for antialiasing when rendering to a multisampled texture.
    public var resolveTexture: Texture?

    /// An optional descriptor that specifies the load and store operations for this attachment.
    ///
    /// - SeeAlso: ``OperationDescriptor``
    public var operation: OperationDescriptor?

    /// The color value to use when clearing the attachment.
    ///
    /// This value is only used when the attachment's load action is set to clear.
    /// If `nil`, the default clear color (typically black) will be used.
    public var clearColor: Color?

    /// Initialize a new render pass color attachment descriptor.
    ///
    /// - Parameter texture: The texture to use as the color attachment target.
    /// - Parameter resolveTexture: An optional texture to resolve multisampled rendering into.
    /// - Parameter operation: An optional descriptor that specifies the load and store operations for this attachment.
    /// - Parameter clearColor: The color value to use when clearing the attachment.
    public init(
        texture: Texture,
        resolveTexture: Texture? = nil,
        operation: OperationDescriptor? = nil,
        clearColor: Color? = nil
    ) {
        self.texture = texture
        self.resolveTexture = resolveTexture
        self.operation = operation
        self.clearColor = clearColor
    }
}
