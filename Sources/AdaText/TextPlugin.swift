//
//  Text2DPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/5/23.
//

import AdaApp
import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

/// Append text rendering systems to the scene.
public struct TextPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        TextComponent.registerComponent()

        app
            .main
            .registerRequiredComponent(TextLayoutComponent.self, for: TextComponent.self) {
                TextLayoutComponent(textLayout: TextLayoutManager())
            }
            .addSystem(TextLayoutSystem.self, on: .postUpdate)

        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        renderWorld
            .insertResource(RenderPipelines(configurator: TextPipeline()))
    }
}

public struct TextPipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>

    public init() {
        self.shader = (try? ShaderModule.loadBundled(at: "Assets/text.glsl", from: .module))
            .unwrap(message: "Bundled text shader is missing.")
    }

    public func configurate(
        with _: RenderPipelineEmptyConfiguration
    ) -> RenderPipelineDescriptor {
        let vertexShader = shader.asset.getShader(for: .vertex)
            .unwrap(message: "Bundled text shader has no vertex stage.")
        var piplineDesc = RenderPipelineDescriptor(vertex: vertexShader)
        piplineDesc.fragment = shader.asset.getShader(for: .fragment)
        piplineDesc.debugName = "Text Pipeline"
        piplineDesc.backfaceCulling = false

        piplineDesc.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "a_Position"),
            .attribute(.vector4, name: "a_ForegroundColor"),
            .attribute(.vector4, name: "a_OutlineColor"),
            .attribute(.float, name: "a_OutlineWidth"),
            .attribute(.vector2, name: "a_TexCoordinate"),
            .attribute(.int, name: "a_TextureIndex"),
        ])

        piplineDesc.vertexDescriptor.layouts[0].stride = MemoryLayout<GlyphVertexData>.stride
        piplineDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]
        return piplineDesc
    }
}

/// Vertex data for rendering text glyphs.
/// Matches the layout expected by text.glsl shader.
public struct GlyphVertexData: Sendable {
    /// Position in world space (vec4).
    public let position: Vector4
    /// Foreground color of the text (vec4).
    public let foregroundColor: Color
    /// Outline color of the text (vec4).
    public let outlineColor: Color
    /// Outline width in screen pixels.
    public let outlineWidth: Float
    /// Texture coordinates for the glyph atlas (vec2).
    public let textureCoordinate: Vector2
    /// Index into the font atlas texture array.
    public let textureIndex: Int

    public init(
        position: Vector4,
        foregroundColor: Color,
        outlineColor: Color,
        outlineWidth: Float,
        textureCoordinate: Vector2,
        textureIndex: Int
    ) {
        self.position = position
        self.foregroundColor = foregroundColor
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
        self.textureCoordinate = textureCoordinate
        self.textureIndex = textureIndex
    }
}
