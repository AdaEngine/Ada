//
//  ShaderUniformValue.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/23/23.
//

import AdaUtils
import Math

/// This protocol describe value type for shader.
/// If you want pass your custom type to shader, you should implement this interface for your type.
/// - Warning: You custom type should have the same size in memory as a ShaderValueType.
public protocol ShaderUniformValue: Sendable {
    static var shaderValueType: ShaderValueType { get }
}

/// This protocol responsible for returning memory size of type.
public protocol ShaderBindable {
    /// The memory layout of a type.
    static func layout() -> Int
}

extension ShaderBindable {
    public static func layout() -> Int {
        return MemoryLayout<Self>.stride
    }
}

// MARK: Base implementation

extension Color: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .vec4
}

extension Vector2: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .vec2
}

extension Vector3: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .vec3
}

extension Vector4: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .vec4
}

extension Float: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .float
}

extension Int: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .int
}

extension UInt: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .uint
}

extension UInt8: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .char
}

extension UInt16: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .short
}

extension Transform3D: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .mat4
}

extension Transform2D: ShaderUniformValue, ShaderBindable {
    public static let shaderValueType: ShaderValueType = .mat3
}

public enum ShaderValueType: String, Codable, Sendable {
    case vec2
    case vec3
    case vec4

    case mat4
    case mat3

    case float
    case half
    case int
    case uint
    case short
    case char
    case bool

    case structure

    case none
}
