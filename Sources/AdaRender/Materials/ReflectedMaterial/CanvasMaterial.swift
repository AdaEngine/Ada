//
//  CanvasMaterial.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/2/23.
//

import AdaAssets
import AdaUtils
import Foundation

private func loadBundledCanvasShaderSource(
    at path: String,
    from bundle: Bundle
) throws -> AssetHandle<ShaderSource> {
    #if WASM
        guard let resourceURL = bundle.resourceURL else {
            throw ShaderSource.Error.failedToRead(path)
        }

        let resourcePath = path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return AssetHandle(try ShaderSource(from: resourceURL.appendingPathComponent(resourcePath)))
    #else
        return try AssetsManager.loadSync(
            ShaderSource.self,
            at: path,
            from: bundle
        )
    #endif
}

/// This material can be render Meshes in 2D world.
public protocol CanvasMaterial: ReflectedMaterial {}

private func canvasVariantModule(at path: String, defines: [ShaderDefine]) throws -> ShaderModule {
    try ShaderModule.createBundled(at: path, from: Bundle.adaModule, defines: defines.map { $0.name })
}

extension CanvasMaterial {
    // The browser keeps the staged GLSL variants until the exporter prelinks these WESL variants.
    #if WASM
        public static var usesVariantShaderModules: Bool { false }
    #else
        public static var usesVariantShaderModules: Bool { ShaderModule.supportsBundledWESL }
    #endif

    public static func variantShaderModule(defines: [ShaderDefine]) throws -> ShaderModule {
        try canvasVariantModule(at: "Shaders/mesh2d/mesh2d.wesl", defines: defines)
    }

    public static func vertexShader() throws -> AssetHandle<ShaderSource> {
        return try loadBundledCanvasShaderSource(
            at: "Shaders/mesh2d/mesh2d.glsl#vert",
            from: Bundle.adaModule
        )
    }

    public static func fragmentShader() throws -> AssetHandle<ShaderSource> {
        return try loadBundledCanvasShaderSource(
            at: "Shaders/mesh2d/mesh2d.glsl#frag",
            from: Bundle.adaModule
        )
    }

    public static func configureShaderDefines(
        keys _: Set<String>,
        vertexDescriptor: VertexDescriptor
    ) -> [ShaderDefine] {
        var defines = [ShaderDefine]()

        if vertexDescriptor.attributes.containsAttribute(by: MeshDescriptor.positions.id.name) {
            defines.append(.define("VERTEX_POSITIONS"))
        }

        if vertexDescriptor.attributes.containsAttribute(by: MeshDescriptor.colors.id.name) {
            defines.append(.define("VERTEX_COLORS"))
        }

        if vertexDescriptor.attributes.containsAttribute(by: MeshDescriptor.normals.id.name) {
            defines.append(.define("VERTEX_NORMALS"))
        }

        if vertexDescriptor.attributes.containsAttribute(by: MeshDescriptor.textureCoordinates.id.name) {
            defines.append(.define("VERTEX_UVS"))
        }

        return defines
    }

    public static func configurePipeline(
        keys _: Set<String>,
        vertex: Shader,
        fragment: Shader,
        vertexDescriptor: VertexDescriptor
    ) throws -> RenderPipelineDescriptor {
        var descriptor = RenderPipelineDescriptor(vertex: vertex)
        descriptor.debugName = "Canvas Mesh Material \(String(describing: self))"
        descriptor.fragment = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        // Canvas geometry must remain visible when a 2D transform mirrors its winding.
        descriptor.backfaceCulling = false
        descriptor.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]

        return descriptor
    }
}

/// Unlit color material. Material will fill all mesh with color.
public struct ColorCanvasMaterial: CanvasMaterial {
    @Uniform(binding: 0, propertyName: "ColorCanvasMaterial")
    public var color: Color

    public init(color: Color) {
        self.color = color
    }

    public static func variantShaderModule(defines: [ShaderDefine]) throws -> ShaderModule {
        try canvasVariantModule(at: "Shaders/Materials/color_canvas_material.wesl", defines: defines)
    }

    public static func fragmentShader() throws -> AssetHandle<ShaderSource> {
        return try loadBundledCanvasShaderSource(
            at: "Shaders/Materials/color_canvas_material.glsl",
            from: Bundle.adaModule
        )
    }
}

/// Circle material will render circle on mesh.
struct CircleCanvasMaterial: CanvasMaterial {
    @Uniform(binding: 0, propertyName: "u_Thickness")
    var thickness: Float

    @Uniform(binding: 0, propertyName: "u_Fade")
    var fade: Float

    @Uniform(binding: 0, propertyName: "u_Color")
    var color: Color

    public static func variantShaderModule(defines: [ShaderDefine]) throws -> ShaderModule {
        try canvasVariantModule(at: "Shaders/Materials/circle_canvas_material.wesl", defines: defines)
    }

    public static func fragmentShader() throws -> AssetHandle<ShaderSource> {
        return try loadBundledCanvasShaderSource(
            at: "Shaders/Materials/circle_canvas_material.glsl",
            from: Bundle.adaModule
        )
    }
}
