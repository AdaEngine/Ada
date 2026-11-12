extension ShaderGraph.ValueType {
    var wgslType: String {
        switch self {
        case .float: "f32"
        case .bool: "bool"
        case .vector2: "vec2f"
        case .vector3: "vec3f"
        case .vector4, .color: "vec4f"
        case .texture2D: "texture_2d<f32>"
        }
    }
}

extension ShaderGraph {
    /// Generates WGSL for the same graph, parameter slots and bindings as ``compileGLSL()``, without touching a GPU.
    ///
    /// The result defines `AdaGraphSurface` and `ada_graph_evaluate(uv: vec2f)`. A WESL template places it before
    /// its entry point; resources live in group ``ShaderGraphProgram/resourceSet`` at the documented bindings.
    /// User identifiers are never interpolated as shader code.
    public func compileWGSL() throws -> ShaderGraphProgram {
        let analysis = try analyzed()
        let ir = analysis.ir
        let parameters = analysis.parameters
        let textures = analysis.textures
        let textureNames = analysis.textureNames
        var lines = [
            "struct AdaGraphUniforms { values: array<vec4f, \(parameters.count + 1)>, };",
            "@group(\(ShaderGraphProgram.resourceSet)) @binding(\(ShaderGraphProgram.uniformBinding)) var<uniform> ada_graph_uniforms: AdaGraphUniforms;"
        ]
        if ir.instructions.contains(where: { $0.operation == .noise2D }) {
            lines += [
                "fn ada_graph_hash(p: vec2u) -> f32 { var h = p.x * 1664525u + p.y * 1013904223u; h = (h ^ (h >> 16u)) * 2246822519u; return f32(h & 16777215u) / 16777215.0; }",
                "fn ada_graph_noise(p: vec2f) -> f32 { let i = vec2u(vec2i(floor(p))); var f = fract(p); f = f * f * (vec2f(3.0) - 2.0 * f);",
                "return mix(mix(ada_graph_hash(i), ada_graph_hash(i + vec2u(1u, 0u)), f.x), mix(ada_graph_hash(i + vec2u(0u, 1u)), ada_graph_hash(i + vec2u(1u)), f.x), f.y); }"
            ]
        }
        if !textures.isEmpty {
            lines.append("@group(\(ShaderGraphProgram.samplerSet)) @binding(\(ShaderGraphProgram.samplerBinding)) var ada_graph_sampler: sampler;")
        }
        for (index, texture) in textures.enumerated() {
            lines.append("@group(\(ShaderGraphProgram.resourceSet)) @binding(\(texture.binding)) var ada_graph_texture\(index): texture_2d<f32>;")
        }
        lines += [
            "struct AdaGraphSurface { color: vec4f, normal: vec3f, metallic: f32, roughness: f32, emission: vec3f, occlusion: f32, alpha: f32, };",
            "fn ada_graph_evaluate(ada_graph_uv: vec2f) -> AdaGraphSurface {",
            "var ada_graph_result: AdaGraphSurface; ada_graph_result.color = vec4f(1.0); ada_graph_result.normal = vec3f(0.0, 0.0, 1.0);",
            "ada_graph_result.metallic = 0.0; ada_graph_result.roughness = 0.5; ada_graph_result.emission = vec3f(0.0); ada_graph_result.occlusion = 1.0; ada_graph_result.alpha = 1.0;"
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
            return link.conversion == .scalarBroadcast ? "\(link.type.wgslType)(\(value))" : value
        }
        for node in ir.instructions {
            let name = names[node.nodeID] ?? "ada_graph_unused"
            func argument(_ port: String) -> String { node.inputs[port].map(input) ?? "0.0" }
            if node.operation == .output {
                for port in node.inputs.keys.sorted() {
                    locations[lines.count + 1] = .init(nodeID: node.nodeID, port: port)
                    lines.append("ada_graph_result.\(port == "baseColor" ? "color" : port) = \(argument(port));")
                }
                continue
            }
            guard let type = node.type, type != .texture2D else { continue }
            let t = type.wgslType
            let expression: String
            switch node.operation {
            case .constant:
                expression = type == .bool ? (node.value == [1] ? "true" : "false")
                    : "\(t)(\(node.value.map(String.init(describing:)).joined(separator: ", ")))"
            case .parameter:
                let slot = parameters.first { $0.id == node.reference }?.slot ?? 0
                let value = "ada_graph_uniforms.values[\(slot)]"
                switch type {
                case .bool: expression = "(\(value).x != 0.0)"
                case .float: expression = value + ".x"
                case .vector2: expression = value + ".xy"
                case .vector3: expression = value + ".xyz"
                default: expression = value
                }
            case .uv: expression = "ada_graph_uv"
            case .time: expression = "ada_graph_uniforms.values[0].x"
            case .spriteTexture: expression = "textureSample(u_Texture, u_Sampler, \(node.inputs["uv"].map(input) ?? "ada_graph_uv"))"
            case .add: expression = "(\(argument("a")) + \(argument("b")))"
            case .multiply: expression = "(\(argument("a")) * \(argument("b")))"
            case .subtract: expression = "(\(argument("a")) - \(argument("b")))"
            case .divide: expression = "((\(argument("a")) / max(abs(\(argument("b"))), \(t)(0.000001))) * sign(\(argument("b"))))"
            case .power: expression = "pow(max(\(argument("a")), \(t)(0.000001)), \(argument("b")))"
            case .minimum: expression = "min(\(argument("a")), \(argument("b")))"
            case .maximum: expression = "max(\(argument("a")), \(argument("b")))"
            case .clamp: expression = "clamp(\(argument("value")), \(argument("min")), \(argument("max")))"
            case .saturate: expression = "clamp(\(argument("value")), \(t)(0.0), \(t)(1.0))"
            case .oneMinus: expression = "(\(t)(1.0) - \(argument("value")))"
            case .sine: expression = "sin(\(argument("value")))"
            case .cosine: expression = "cos(\(argument("value")))"
            case .absolute: expression = "abs(\(argument("value")))"
            case .fraction: expression = "fract(\(argument("value")))"
            case .floor: expression = "floor(\(argument("value")))"
            case .step: expression = "step(\(argument("edge")), \(argument("value")))"
            case .smoothstep: expression = "smoothstep(\(argument("edge0")), \(argument("edge1")), \(argument("value")))"
            case .noise2D: expression = "ada_graph_noise(\(argument("uv")))"
            case .combine2: expression = "vec2f(\(argument("x")), \(argument("y")))"
            case .combine3: expression = "vec3f(\(argument("x")), \(argument("y")), \(argument("z")))"
            case .combine4: expression = "vec4f(\(argument("x")), \(argument("y")), \(argument("z")), \(argument("w")))"
            case .select: expression = "select(\(argument("b")), \(argument("a")), \(argument("condition")))"
            case .lerp: expression = "mix(\(argument("a")), \(argument("b")), \(argument("t")))"
            case .sampleTexture: expression = "textureSample(\(argument("texture")), ada_graph_sampler, \(argument("uv")))"
            case .texture, .output: continue
            }
            locations[lines.count + 1] = .init(nodeID: node.nodeID, port: nil)
            lines.append("let \(name): \(t) = \(expression);")
        }
        lines += ["return ada_graph_result;", "}"]
        return ShaderGraphProgram(
            target: target,
            renderSettings: renderSettings,
            source: lines.joined(separator: "\n"),
            parameters: parameters,
            textures: textures,
            sourceMap: locations,
            usesTime: ir.instructions.contains { $0.operation == .time },
            format: .wgsl
        )
    }
}
