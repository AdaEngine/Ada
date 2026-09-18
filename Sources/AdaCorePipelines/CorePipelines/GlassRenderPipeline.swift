//
//  GlassRenderPipeline.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Math

/// Vertex data for rendering glass quads.
/// Matches the attribute layout expected by glass.glsl.
public struct GlassVertexData: Sendable {
    /// Position in world space (vec4).
    public let position: Vector4
    /// Optional tint color overlay (vec4). Alpha controls blend strength.
    public let color: Color
    /// Local UV coordinates [0,1] across the quad (vec2).
    public let texCoord: Vector2
    /// Glass visual parameters (vec4):
    /// x = blurRadius (logical pixels), y = cornerRadius (logical pixels),
    /// z = glassTintStrength [0,1], w = edgeShadowStrength [0,1].
    public let glassParams0: Vector4
    /// Advanced optical parameters (vec4):
    /// x = cornerRoundnessExponent, y = glassThickness,
    /// z = refractiveIndex, w = dispersionStrength.
    public let glassParams1: Vector4
    /// Fresnel and glare range parameters (vec4):
    /// x = fresnelDistanceRange, y = fresnelIntensity,
    /// z = fresnelEdgeSharpness, w = glareDistanceRange.
    public let glassParams2: Vector4
    /// Glare shaping parameters (vec4):
    /// x = glareAngleConvergence, y = glareOppositeSideBias,
    /// z = glareIntensity, w = glareEdgeSharpness.
    public let glassParams3: Vector4
    /// Glass geometry and display info (vec4):
    /// x = halfWidth, y = halfHeight (logical pixels),
    /// z = display scaleFactor, w = opacity [0,1].
    public let glassInfo0: Vector4
    /// Additional info (vec4):
    /// x = glareDirectionOffset, yzw reserved.
    public let glassInfo1: Vector4

    public init(
        position: Vector4,
        color: Color,
        texCoord: Vector2,
        glassParams0: Vector4,
        glassParams1: Vector4,
        glassParams2: Vector4,
        glassParams3: Vector4,
        glassInfo0: Vector4,
        glassInfo1: Vector4
    ) {
        self.position = position
        self.color = color
        self.texCoord = texCoord
        self.glassParams0 = glassParams0
        self.glassParams1 = glassParams1
        self.glassParams2 = glassParams2
        self.glassParams3 = glassParams3
        self.glassInfo0 = glassInfo0
        self.glassInfo1 = glassInfo1
    }
}

/// Pipeline configurator for rendering glass quads.
public struct GlassPipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>

    public init() {
        self.shader = ShaderModule.loadRequiredBundled(at: "Shaders/glass.glsl", from: .module)
    }

    public func configurate(
        with _: RenderPipelineEmptyConfiguration
    ) -> RenderPipelineDescriptor {
        var pipelineDesc = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        pipelineDesc.fragment = shader.asset.getShader(for: .fragment)
        pipelineDesc.debugName = "Glass Pipeline"
        pipelineDesc.backfaceCulling = false

        pipelineDesc.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "a_Position"),
            .attribute(.vector4, name: "a_Color"),
            .attribute(.vector2, name: "a_TexCoordinate"),
            .attribute(.vector4, name: "a_GlassParams0"),
            .attribute(.vector4, name: "a_GlassParams1"),
            .attribute(.vector4, name: "a_GlassParams2"),
            .attribute(.vector4, name: "a_GlassParams3"),
            .attribute(.vector4, name: "a_GlassInfo0"),
            .attribute(.vector4, name: "a_GlassInfo1"),
        ])

        pipelineDesc.vertexDescriptor.layouts[0].stride = MemoryLayout<GlassVertexData>.stride
        pipelineDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]
        return pipelineDesc
    }
}
