import Foundation
#if canImport(SAGACompiler) && canImport(SAGAShaderIR)
import SAGACompiler
import SAGAShaderIR
#endif

/// Compiler diagnostics retain graph identity in addition to the backend's technical detail.
public struct ShaderGraphCompilationError: LocalizedError, Sendable {
    public let message: String
    public let nodeID: String?
    public let port: String?

    public var errorDescription: String? { message }
}

extension ShaderGraphProgram {
    /// Whether this build includes SAGA's CPU shader validator.
    public static var supportsWGSLValidation: Bool {
        #if canImport(SAGACompiler) && canImport(SAGAShaderIR)
            true
        #else
            false
        #endif
    }

    /// Validates generated WGSL as a fragment shader without accessing the render device.
    public func validateWGSL() throws {
        #if canImport(SAGACompiler) && canImport(SAGAShaderIR)
            let prefix = """
                @group(0) @binding(0) var u_Texture: texture_2d<f32>;
                @group(0) @binding(1) var u_Sampler: sampler;
                """ + "\n"
            let suffix = "\n@fragment fn main() -> @location(0) vec4f { return ada_graph_evaluate(vec2f(0.5)).color; }"
            do {
                _ = try IndependentShaderCompiler().parseAndValidate(.wgsl(prefix + source + suffix))
            } catch ShaderFailure.diagnostics(let diagnostics) {
                let diagnostic = diagnostics.first { $0.severity == .error } ?? diagnostics.first
                let location = diagnostic?.span.flatMap { span -> Location? in
                    let offset = span.startUTF8 - prefix.utf8.count
                    guard offset >= 0, offset < source.utf8.count else {
                        return nil
                    }
                    let line = 1 + source.utf8.prefix(offset).count { $0 == 10 }
                    return sourceMap[line]
                }
                throw ShaderGraphCompilationError(
                    message: diagnostic?.message ?? "SAGA could not validate the Shader Graph.",
                    nodeID: location?.nodeID,
                    port: location?.port
                )
            }
        #else
            throw ShaderGraphCompilationError(message: "This build does not include the SAGA WGSL validator.", nodeID: nil, port: nil)
        #endif
    }


    /// Inserts the graph program into its renderer template.
    public func inserting(in template: String) -> String {
        return template.replacingOccurrences(of: "// ADA_GRAPH_SOURCE_MARKER", with: source)
    }
}
