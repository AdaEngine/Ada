//
//  ReflectedMaterial.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/2/23.
//

import AdaAssets

/// The base interface for all custom materials.
/// If you need create a custom material for your game, declare struct with fields and decorate them using ``Uniform`` or ``FragmentTexture`` property wrappers.
///
/// ```
/// struct MyCustomMaterial: ReflectedMaterial {
///
///     // By default reflected material will use difined property name.
///     @Uniform(binding: 0)
///     var color: Color = .red // Default color
///
///     // If your material member name is different than shader uniform member name,
///     // you can override property name like so:
///     @Uniform(binding: 0, propertyName: "delta_time")
///     var deltaTime: Float
///
///     // You can pass textures into shader
///     @FragmentTexture(binding: 0)
///     var noiseTexture: Texture2D
/// }
///
/// ```
///
/// When you declared material struct, you can pass it to the ``CustomMaterial`` object where main magic happens.
///
public protocol ReflectedMaterial: ShaderBindable {
    /// Configure and pass shader source for custom material.
    /// - Returns: A shader sources for vertex shader.
    static func vertexShader() throws -> AssetHandle<ShaderSource>

    /// Configure and pass shader source for custom material.
    /// - Returns: A shader sources for fragment shader.
    static func fragmentShader() throws -> AssetHandle<ShaderSource>

    /// Configure shader defines for specific vertex descriptor and keys.
    /// You can use this method to configure definitions specificly for you shader code.
    /// - Parameter keys: The set of keys for specific environment.
    /// - Parameter vertexDescriptor: The vertex desciptor from mesh.
    /// - Returns: Shader macro defines for vertex and fragment shaders.
    static func configureShaderDefines(
        keys: Set<String>,
        vertexDescriptor: VertexDescriptor
    ) -> [ShaderDefine]

    /// Configure render pipeline with given keys, shaders and vertex descriptor.
    /// You can use this method to configure render pipeline whatever you want.
    /// - Parameter keys: The set of keys for specific environment.
    /// - Parameter vertex: Compiled vertex shader with specific defines.
    /// - Parameter fragment: Compiled fragment shader with specific defines.
    /// - Parameter vertexDescriptor: The vertex desciptor from mesh.
    /// - Returns: A new render pipeline descriptor.
    static func configurePipeline(
        keys: Set<String>,
        vertex: Shader,
        fragment: Shader,
        vertexDescriptor: VertexDescriptor
    ) throws -> RenderPipelineDescriptor
}
