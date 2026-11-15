/// Generated fragment functions and their renderer-independent binding contract.
public struct ShaderGraphProgram: Hashable, Sendable {
    // All graph resources live in group 1. Native slot choices also avoid the
    // stock fragment LocalShadow/LightTiles buffers and fit Metal's sampler limit.
    public static let resourceSet = 1
    public static let uniformBinding = 24
    public static let samplerBinding = 14
    public static let samplerSet = resourceSet
    public static let firstTextureBinding = 48

    public struct Parameter: Hashable, Sendable {
        public let id: String
        public let type: ShaderGraph.ValueType
        public let defaultValue: [Float]
        /// One aligned vec4 per parameter; slot zero contains animation time.
        public let slot: Int
        /// Authored display label; the stable `id` remains the binding identity.
        public let displayName: String?
    }

    public struct Texture: Hashable, Sendable {
        public let parameterID: String?
        public let path: String?
        public let binding: Int
        public let displayName: String?
    }

    public struct Location: Hashable, Sendable {
        public let nodeID: String
        public let port: String?
    }

    public let target: ShaderGraph.Target
    public let renderSettings: ShaderGraph.RenderSettings
    /// Cache shaders by this source, not parameter defaults, resource paths or layout.
    public let source: String
    public let parameters: [Parameter]
    public let textures: [Texture]
    public let sourceMap: [Int: Location]
    public let usesTime: Bool
    /// The language of ``source``.
    public var format: SourceFormat = .wgsl

    public enum SourceFormat: String, Hashable, Sendable {
        case wgsl
    }
}


extension ShaderGraph {
    /// Parameters, texture bindings and texture names derived from the lowered graph. Shared by every source
    /// language so slots and bindings never differ between them.
    struct Analysis {
        var ir: ShaderGraphIR
        var parameters: [ShaderGraphProgram.Parameter]
        var textures: [ShaderGraphProgram.Texture]
        var textureNames: [String: String]
    }

    func analyzed() throws -> Analysis {
        let ir = try lowered()
        let numeric = ir.instructions.filter { $0.operation == .parameter && $0.type != .texture2D }
        let ids = Set(numeric.compactMap(\.reference)).sorted()
        let parameters: [ShaderGraphProgram.Parameter] = ids.enumerated().compactMap { index, id in
            guard let node = numeric.first(where: { $0.reference == id }), let type = node.type else {
                return nil
            }
            return .init(id: id, type: type, defaultValue: node.value, slot: index + 1, displayName: nodes.first { $0.id == node.nodeID }?.label)
        }
        var textures: [ShaderGraphProgram.Texture] = []
        var textureNames: [String: String] = [:]
        for node in ir.instructions where node.type == .texture2D {
            let parameter = node.operation == .parameter ? node.reference : nil
            let path = node.operation == .texture ? node.reference : nodes.first { $0.id == node.nodeID }?.defaultTexture
            let index: Int
            if let existing = textures.firstIndex(where: { $0.parameterID == parameter && $0.path == path }) {
                index = existing
            } else {
                index = textures.count
                textures.append(.init(parameterID: parameter, path: path, binding: ShaderGraphProgram.firstTextureBinding + index, displayName: nodes.first { $0.id == node.nodeID }?.label))
            }
            textureNames[node.nodeID] = "ada_graph_texture\(index)"
        }
        return Analysis(ir: ir, parameters: parameters, textures: textures, textureNames: textureNames)
    }
}
