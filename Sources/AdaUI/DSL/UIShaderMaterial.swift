//
//  UIShaderMaterial.swift
//  AdaEngine
//

import AdaAssets
import AdaCorePipelines
import AdaRender

/// A reflected material that renders into an AdaUI view bounds as a quad.
///
/// Use this with ``CustomMaterial`` and ``View/shaderEffect(_:placement:)``.
public protocol UIShaderMaterial: ReflectedMaterial {}

extension UIShaderMaterial {
    public static func vertexShader() throws -> AssetHandle<ShaderSource> {
        let source = """
            #version 450 core
            #pragma stage : vert

            #include <AdaEngine/View.glsl>

            layout (location = 0) in vec4 a_Position;
            layout (location = 1) in vec4 a_Color;
            layout (location = 2) in vec2 a_TexCoordinate;

            struct VertexOut
            {
                vec4 Color;
                vec2 UV;
            };

            layout (location = 0) out VertexOut Output;

            [[main]]
            void ui_shader_material_vertex()
            {
                Output.Color = a_Color;
                Output.UV = a_TexCoordinate;
                gl_Position = u_ViewProjection * a_Position;
            }
            """
        return AssetHandle(try ShaderSource(source: source))
    }

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
