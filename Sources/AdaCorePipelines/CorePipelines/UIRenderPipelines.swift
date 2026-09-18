//
//  UIRenderPipelines.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 19.12.2025.
//

import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Foundation
import Math

public enum CorePipelineShaders {
    public static func loadBundled(at path: String) throws -> AssetHandle<ShaderModule> {
        try ShaderModule.loadBundled(at: path, from: .module)
    }

    public static func loadRequiredBundled(at path: String) -> AssetHandle<ShaderModule> {
        ShaderModule.loadRequiredBundled(at: path, from: .module)
    }
}

// MARK: - Quad Pipeline

/// Pipeline configurator for rendering UI quads.
public struct QuadPipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>

    public init() {
        self.shader = ShaderModule.loadRequiredBundled(at: "Shaders/quad.glsl", from: .module)
    }

    public func configurate(
        with _: RenderPipelineEmptyConfiguration
    ) -> RenderPipelineDescriptor {
        var pipelineDesc = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        pipelineDesc.fragment = shader.asset.getShader(for: .fragment)
        pipelineDesc.debugName = "Quad Pipeline"
        pipelineDesc.backfaceCulling = false

        pipelineDesc.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "a_Position"),
            .attribute(.vector4, name: "a_Color"),
            .attribute(.vector2, name: "a_TexCoordinate"),
        ])

        pipelineDesc.vertexDescriptor.layouts[0].stride = MemoryLayout<QuadVertexData>.stride
        pipelineDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]
        return pipelineDesc
    }
}

// MARK: - Gradient Pipeline

/// Pipeline configurator for rendering UI linear gradients.
public struct LinearGradientPipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>

    public init() {
        self.shader = ShaderModule.loadRequiredBundled(at: "Shaders/gradient.glsl", from: .module)
    }

    public func configurate(
        with _: RenderPipelineEmptyConfiguration
    ) -> RenderPipelineDescriptor {
        var pipelineDesc = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        pipelineDesc.fragment = shader.asset.getShader(for: .fragment)
        pipelineDesc.debugName = "Linear Gradient Pipeline"
        pipelineDesc.backfaceCulling = false

        pipelineDesc.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "a_Position"),
            .attribute(.vector4, name: "a_Color"),
            .attribute(.vector2, name: "a_TexCoordinate"),
        ])

        pipelineDesc.vertexDescriptor.layouts[0].stride = MemoryLayout<QuadVertexData>.stride
        pipelineDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]
        return pipelineDesc
    }
}

// MARK: - Circle Pipeline

/// Pipeline configurator for rendering UI circles.
public struct CirclePipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>

    public init() {
        self.shader = ShaderModule.loadRequiredBundled(at: "Shaders/circle.glsl", from: .module)
    }

    public func configurate(
        with _: RenderPipelineEmptyConfiguration
    ) -> RenderPipelineDescriptor {
        var pipelineDesc = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        pipelineDesc.fragment = shader.asset.getShader(for: .fragment)
        pipelineDesc.debugName = "Circle Pipeline"
        pipelineDesc.backfaceCulling = false

        pipelineDesc.vertexDescriptor.attributes.append([
            .attribute(.vector3, name: "a_WorldPosition"),
            .attribute(.vector2, name: "a_LocalPosition"),
            .attribute(.float, name: "a_Thickness"),
            .attribute(.float, name: "a_Fade"),
            .attribute(.vector4, name: "a_Color"),
        ])

        pipelineDesc.vertexDescriptor.layouts[0].stride = MemoryLayout<CircleVertexData>.stride
        pipelineDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]
        return pipelineDesc
    }
}

// MARK: - Line Pipeline

/// Pipeline configurator for rendering UI lines.
public struct LinePipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>

    public init() {
        self.shader = ShaderModule.loadRequiredBundled(at: "Shaders/line.glsl", from: .module)
    }

    public func configurate(
        with _: RenderPipelineEmptyConfiguration
    ) -> RenderPipelineDescriptor {
        var pipelineDesc = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        pipelineDesc.fragment = shader.asset.getShader(for: .fragment)
        pipelineDesc.debugName = "Line Pipeline"
        pipelineDesc.backfaceCulling = false
        pipelineDesc.primitive = .line

        pipelineDesc.vertexDescriptor.attributes.append([
            .attribute(.vector3, name: "a_Position"),
            .attribute(.vector4, name: "a_Color"),
            .attribute(.float, name: "a_LineWidth"),
        ])

        pipelineDesc.vertexDescriptor.layouts[0].stride = MemoryLayout<LineVertexData>.stride
        pipelineDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]
        return pipelineDesc
    }
}

/// Vertex data for rendering quads (rectangles with optional textures).
/// Matches the layout expected by quad.glsl shader.
public struct QuadVertexData: Sendable {
    /// Position in world space (vec4).
    public let position: Vector4
    /// Color of the quad (vec4).
    public let color: Color
    /// Texture coordinates (vec2).
    public let textureCoordinate: Vector2
    /// Index into the texture array.
    public let textureIndex: Int

    public init(
        position: Vector4,
        color: Color,
        textureCoordinate: Vector2,
        textureIndex: Int
    ) {
        self.position = position
        self.color = color
        self.textureCoordinate = textureCoordinate
        self.textureIndex = textureIndex
    }
}

/// Vertex data for rendering circles/ellipses.
/// Matches the layout expected by circle.glsl shader.
public struct CircleVertexData: Sendable {
    /// Position in world space (vec3).
    public let worldPosition: Vector3
    /// Position in local space for circle SDF calculation (vec2).
    public let localPosition: Vector2
    /// Thickness of the circle stroke.
    public let thickness: Float
    /// Fade value for anti-aliasing.
    public let fade: Float
    /// Color of the circle (vec4).
    public let color: Color

    public init(
        worldPosition: Vector3,
        localPosition: Vector2,
        thickness: Float,
        fade: Float,
        color: Color
    ) {
        self.worldPosition = worldPosition
        self.localPosition = localPosition
        self.thickness = thickness
        self.fade = fade
        self.color = color
    }
}

/// Vertex data for rendering lines.
/// Matches the layout expected by line.glsl shader.
public struct LineVertexData: Sendable {
    /// Position in world space (vec3).
    public let position: Vector3
    /// Color of the line (vec4).
    public let color: Color
    /// Width of the line.
    public let lineWidth: Float

    public init(
        position: Vector3,
        color: Color,
        lineWidth: Float
    ) {
        self.position = position
        self.color = color
        self.lineWidth = lineWidth
    }
}
