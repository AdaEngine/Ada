import Foundation

/// Compiler diagnostics retain graph identity in addition to the backend's technical detail.
public struct ShaderGraphCompilationError: Error, Sendable {
    public let message: String
    public let nodeID: String?
    public let port: String?
}

extension ShaderGraphProgram {
    /// A CPU-only compilation through the same glslang frontend as production rendering.
    public func validateGLSL() throws {
        let prefix = """
            #version 450
            layout(set = 0, binding = 0) uniform texture2D u_Texture;
            layout(set = 0, binding = 1) uniform sampler u_Sampler;
            layout(location = 0) out vec4 COLOR;
            #line 1 101
            """
        do { _ = try ShaderCompiler.validateFragmentGLSL(prefix + "\n" + source + "\n#line 1 0\nvoid main() { COLOR = ada_graph_evaluate(vec2(0.5)).color; }") } catch {
            throw diagnostic(for: String(describing: error))
        }
    }

    public func diagnostic(for message: String) -> ShaderGraphCompilationError {
        let pattern = #"(?:ERROR|WARNING):\s*101:(\d+)"#
        let match = (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
        let line = match.flatMap { Range($0.range(at: 1), in: message) }.flatMap { Int(message[$0]) }
        let location = line.flatMap { line in sourceMap.keys.filter { $0 <= line }.max().flatMap { sourceMap[$0] } }
        return .init(message: message, nodeID: location?.nodeID, port: location?.port)
    }

    /// Preserve virtual source numbers when composing a renderer's fragment template.
    public func inserting(in template: String) -> String {
        if format == .wgsl {
            return template.replacingOccurrences(of: "// ADA_GRAPH_SOURCE_MARKER", with: source)
        }
        let marker = "#define ADA_GRAPH_SOURCE_MARKER 1"
        let line = template.components(separatedBy: marker).first?.filter { $0 == "\n" }.count ?? 0
        return template.replacingOccurrences(of: marker, with: "#line 1 101\n" + source + "\n#line \(line + 2) 0")
    }
}
