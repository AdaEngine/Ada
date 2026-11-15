//
//  UIShaderMaterial.swift
//  AdaEngine
//

import AdaRender

/// A reflected material that renders into an AdaUI view bounds as a quad.
///
/// Use this with ``CustomMaterial`` and ``View/shaderEffect(_:placement:)``.
public protocol UIShaderMaterial: ReflectedMaterial {}

extension UIShaderMaterial {
    public static func configureShaderDefines(
        keys _: Set<String>,
        vertexDescriptor _: VertexDescriptor
    ) -> [ShaderDefine] {
        []
    }

    public static func configurePipeline(
        keys _: Set<String>,
        vertex: Shader,
        fragment: Shader,
        vertexDescriptor: VertexDescriptor
    ) throws -> RenderPipelineDescriptor {
        var descriptor = RenderPipelineDescriptor(vertex: vertex)
        descriptor.debugName = "UI Shader Material \(String(describing: Self.self))"
        descriptor.fragment = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.backfaceCulling = true
        descriptor.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]
        return descriptor
    }
}
