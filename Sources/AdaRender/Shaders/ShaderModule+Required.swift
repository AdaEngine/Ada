//
//  ShaderModule+Required.swift
//  AdaEngine
//

import AdaAssets
import Foundation

public extension ShaderModule {
    /// Loads a shader that is required for a built-in render pipeline.
    ///
    /// Missing built-in shaders are packaging errors, so this method terminates with
    /// the original loading diagnostic instead of propagating an unrecoverable error.
    static func loadRequiredBundled(at path: String, from bundle: Bundle) -> AssetHandle<ShaderModule> {
        do {
            return try loadBundled(at: path, from: bundle)
        } catch {
            preconditionFailure("Required bundled shader '\(path)' could not be loaded: \(error)")
        }
    }

    /// Returns a required stage from a built-in shader module.
    func requiredShader(for stage: ShaderStage) -> Shader {
        guard let shader = getShader(for: stage) else {
            preconditionFailure("Required shader stage '\(stage)' is missing.")
        }
        return shader
    }
}
