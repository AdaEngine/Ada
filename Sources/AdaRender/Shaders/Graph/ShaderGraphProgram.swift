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
    /// The language of ``source``. GLSL stays until every template that embeds graphs is ported to WESL.
    public var format: SourceFormat = .glsl

    public enum SourceFormat: String, Hashable, Sendable {
        case glsl
        case wgsl
    }
}

extension ShaderGraph.ValueType {
    var glslType: String {
        switch self {
        case .float: "float"
        case .bool: "bool"
        case .vector2: "vec2"
        case .vector3: "vec3"
        case .vector4, .color: "vec4"
        case .texture2D: "texture2D"
        }
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

extension ShaderGraph {
    /// Generates GLSL without touching a GPU. User identifiers are never interpolated as shader code.
    public func compileGLSL() throws -> ShaderGraphProgram {
        let analysis = try analyzed()
        let ir = analysis.ir
        let parameters = analysis.parameters
        let textures = analysis.textures
        let textureNames = analysis.textureNames
        var lines = [
            "layout(set = \(ShaderGraphProgram.resourceSet), binding = \(ShaderGraphProgram.uniformBinding)) uniform AdaGraphUniforms { vec4 ada_graph_values[\(parameters.count + 1)]; };"
        ]
        if ir.instructions.contains(where: { $0.operation == .noise2D }) {
            lines += [
                "float ada_graph_hash(uvec2 p) { uint h = p.x * 1664525u + p.y * 1013904223u; h = (h ^ (h >> 16u)) * 2246822519u; return float(h & 16777215u) / 16777215.0; }",
                "float ada_graph_noise(vec2 p) { uvec2 i = uvec2(ivec2(floor(p))); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);",
                "return mix(mix(ada_graph_hash(i), ada_graph_hash(i + uvec2(1u, 0u)), f.x), mix(ada_graph_hash(i + uvec2(0u, 1u)), ada_graph_hash(i + uvec2(1u)), f.x), f.y); }"
            ]
        }
        if !textures.isEmpty {
            lines.append("layout(set = \(ShaderGraphProgram.samplerSet), binding = \(ShaderGraphProgram.samplerBinding)) uniform sampler ada_graph_sampler;")
        }
        for (index, texture) in textures.enumerated() {
            lines.append("layout(set = \(ShaderGraphProgram.resourceSet), binding = \(texture.binding)) uniform texture2D ada_graph_texture\(index);")
        }
        lines += [
            "struct AdaGraphSurface { vec4 color; vec3 normal; float metallic; float roughness; vec3 emission; float occlusion; float alpha; };",
            "AdaGraphSurface ada_graph_evaluate(vec2 ada_graph_uv) {",
            "AdaGraphSurface surface; surface.color = vec4(1.0); surface.normal = vec3(0.0, 0.0, 1.0);",
            "surface.metallic = 0.0; surface.roughness = 0.5; surface.emission = vec3(0.0); surface.occlusion = 1.0; surface.alpha = 1.0;"
        ]
        let names = Dictionary(uniqueKeysWithValues: ir.instructions.enumerated().map { ($1.nodeID, "ada_graph_n\($0)") })
        var locations: [Int: ShaderGraphProgram.Location] = [:]
        func input(_ link: ShaderGraphIR.Input) -> String {
            let base = textureNames[link.source.node] ?? names[link.source.node] ?? "0.0"
            let suffix: String
            switch link.source.port {
            case "rgb": suffix = ".rgb"
            case "alpha": suffix = ".a"
            case "x", "y", "z", "w": suffix = "." + link.source.port
            default: suffix = ""
            }
            let value = base + suffix
            return link.conversion == .scalarBroadcast ? "\(link.type.glslType)(\(value))" : value
        }
        for node in ir.instructions {
            let name = names[node.nodeID] ?? "ada_graph_unused"
            func argument(_ port: String) -> String { node.inputs[port].map(input) ?? "0.0" }
            if node.operation == .output {
                for port in node.inputs.keys.sorted() {
                    locations[lines.count + 1] = .init(nodeID: node.nodeID, port: port)
                    lines.append("surface.\(port == "baseColor" ? "color" : port) = \(argument(port));")
                }
                continue
            }
            guard let type = node.type, type != .texture2D else { continue }
            let expression: String
            switch node.operation {
            case .constant:
                expression = type == .bool ? (node.value == [1] ? "true" : "false")
                    : "\(type.glslType)(\(node.value.map(String.init(describing:)).joined(separator: ", ")))"
            case .parameter:
                let slot = parameters.first { $0.id == node.reference }?.slot ?? 0
                let value = "ada_graph_values[\(slot)]"
                switch type {
                case .bool: expression = "(\(value).x != 0.0)"
                case .float: expression = value + ".x"
                case .vector2: expression = value + ".xy"
                case .vector3: expression = value + ".xyz"
                default: expression = value
                }
            case .uv: expression = "ada_graph_uv"
            case .time: expression = "ada_graph_values[0].x"
            case .spriteTexture: expression = "texture(sampler2D(u_Texture, u_Sampler), \(node.inputs["uv"].map(input) ?? "ada_graph_uv"))"
            case .add: expression = "(\(argument("a")) + \(argument("b")))"
            case .multiply: expression = "(\(argument("a")) * \(argument("b")))"
            case .subtract: expression = "(\(argument("a")) - \(argument("b")))"
            case .divide: expression = "((\(argument("a")) / max(abs(\(argument("b"))), \(type.glslType)(0.000001))) * sign(\(argument("b"))))"
            case .power: expression = "pow(max(\(argument("a")), \(type.glslType)(0.000001)), \(argument("b")))"
            case .minimum: expression = "min(\(argument("a")), \(argument("b")))"
            case .maximum: expression = "max(\(argument("a")), \(argument("b")))"
            case .clamp: expression = "clamp(\(argument("value")), \(argument("min")), \(argument("max")))"
            case .saturate: expression = "clamp(\(argument("value")), \(type.glslType)(0.0), \(type.glslType)(1.0))"
            case .oneMinus: expression = "(\(type.glslType)(1.0) - \(argument("value")))"
            case .sine: expression = "sin(\(argument("value")))"
            case .cosine: expression = "cos(\(argument("value")))"
            case .absolute: expression = "abs(\(argument("value")))"
            case .fraction: expression = "fract(\(argument("value")))"
            case .floor: expression = "floor(\(argument("value")))"
            case .step: expression = "step(\(argument("edge")), \(argument("value")))"
            case .smoothstep: expression = "smoothstep(\(argument("edge0")), \(argument("edge1")), \(argument("value")))"
            case .noise2D: expression = "ada_graph_noise(\(argument("uv")))"
            case .combine2: expression = "vec2(\(argument("x")), \(argument("y")))"
            case .combine3: expression = "vec3(\(argument("x")), \(argument("y")), \(argument("z")))"
            case .combine4: expression = "vec4(\(argument("x")), \(argument("y")), \(argument("z")), \(argument("w")))"
            case .select: expression = "(\(argument("condition")) ? \(argument("a")) : \(argument("b")))"
            case .lerp: expression = "mix(\(argument("a")), \(argument("b")), \(argument("t")))"
            case .sampleTexture: expression = "texture(sampler2D(\(argument("texture")), ada_graph_sampler), \(argument("uv")))"
            case .texture, .output: continue
            }
            locations[lines.count + 1] = .init(nodeID: node.nodeID, port: nil)
            lines.append("\(type.glslType) \(name) = \(expression);")
        }
        lines += ["return surface;", "}"]
        return ShaderGraphProgram(
            target: target,
            renderSettings: renderSettings,
            source: lines.joined(separator: "\n"),
            parameters: parameters,
            textures: textures,
            sourceMap: locations,
            usesTime: ir.instructions.contains { $0.operation == .time }
        )
    }
}
