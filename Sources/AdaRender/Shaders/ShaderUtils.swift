//
//  ShaderUtils.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/13/23.
//

// FIXME: Replace NSRegularExpression on full swift implementation.
// Currently Swift Regex doesn't supports on macOS less than 13.0 and that's a problem here.
// I want to use swift like solution instead of Foundation.


/// Collection of utils for works with shaders.
enum ShaderUtils {
    /// Return shader language from file extension.
    static func shaderLang(from fileExt: String) -> ShaderLanguage {
        switch fileExt {
        case "hlsl":
            return .hlsl
        case "wgsl":
            return .wgsl
        default:
            return .glsl
        }
    }

}
