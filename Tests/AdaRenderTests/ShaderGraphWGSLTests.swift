#if canImport(AdaWGSLCompiler) && !os(WASI) && !os(Android)
    import AdaWGSLCompiler
    @testable import AdaRender
    import Foundation
    import Testing

    /// The WGSL generator must accept every graph the GLSL generator accepts and keep the same binding contract.
    @Suite("Generated WGSL shader graph functions", .serialized)
    struct ShaderGraphWGSLTests {
        private static let operations: [ShaderGraph.Operation] = [
            .subtract, .divide, .power, .minimum, .maximum, .clamp, .saturate, .oneMinus, .sine, .cosine, .absolute,
            .fraction, .floor, .step, .smoothstep, .lerp, .add, .multiply,
        ]

        private func link(_ program: ShaderGraphProgram) throws -> WESLHostCompiler.Artifact {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("main.wesl")
            try """
            \(program.source)
            @fragment fn main() -> @location(0) vec4f {
                let surface = ada_graph_evaluate(vec2f(0.5));
                return surface.color + vec4f(surface.emission, 0.0) + vec4f(surface.alpha);
            }
            """.write(to: file, atomically: true, encoding: .utf8)
            return try WESLHostCompiler.compile(sourceFile: file, packageRoot: root)
        }

        @Test(arguments: operations)
        func mathNodesLinkWithScalarAndVectorInputs(_ operation: ShaderGraph.Operation) throws {
            for type in [ShaderGraph.ValueType.float, .vector2, .vector3, .vector4, .color] {
                var graph = ShaderGraph(target: .sprite, output: "output", nodes: [])
                var operationNode = ShaderGraph.Node(id: "effect", operation: operation, type: type)
                for port in graph.inputPorts(for: operationNode).keys {
                    graph.nodes.append(.init(id: port, operation: .constant, value: [0.7]))
                    operationNode.inputs[port] = .init(port)
                }
                graph.nodes.append(operationNode)
                graph.nodes.append(.init(id: "output", operation: .output, inputs: ["alpha": .init("effect", port: type == .float ? "value" : "x")]))
                let program = try graph.compileWGSL()
                #expect(program.format == .wgsl)
                let module = try link(program)
                #expect(module.entryPoints.map(\.name) == ["main"])
            }
        }

        @Test func proceduralNoiseAndExplicitVectorChannelsLink() throws {
            let graph = ShaderGraph(
                target: .pbrSurface,
                output: "output",
                nodes: [
                    .init(id: "x", operation: .constant, value: [-0.25]),
                    .init(id: "uv", operation: .combine2, type: .vector2, inputs: ["x": .init("x"), "y": .init("x")]),
                    .init(id: "noise", operation: .noise2D, inputs: ["uv": .init("uv")]),
                    .init(id: "color", operation: .combine4, type: .vector4, inputs: ["x": .init("noise"), "y": .init("noise"), "z": .init("noise"), "w": .init("x")]),
                    .init(id: "output", operation: .output, inputs: ["baseColor": .init("color", port: "color")]),
                ]
            )
            let program = try graph.compileWGSL()
            #expect(program.source.contains("ada_graph_noise"))
            _ = try link(program)
        }

        private func texturedGraph() -> ShaderGraph {
            ShaderGraph(target: .pbrSurface, output: "output", nodes: [
                .init(id: "uv", operation: .uv, type: .vector2),
                .init(id: "texture", operation: .texture, type: .texture2D, reference: "stone.png"),
                .init(id: "sample", operation: .sampleTexture, type: .vector4, inputs: ["texture": .init("texture"), "uv": .init("uv")]),
                .init(id: "tint", operation: .parameter, type: .color, value: [1, 1, 1, 1], reference: "tint; invalid shader identifier"),
                .init(id: "time", operation: .time),
                .init(id: "multiply", operation: .multiply, type: .color, inputs: ["a": .init("sample", port: "color"), "b": .init("tint")]),
                .init(id: "output", operation: .output, inputs: ["baseColor": .init("multiply"), "emission": .init("sample", port: "rgb"), "alpha": .init("time")]),
            ])
        }

        @Test func bindingsAndParameterSlotsMatchTheGLSLProgram() throws {
            let graph = texturedGraph()
            let glsl = try graph.compileGLSL()
            let wgsl = try graph.compileWGSL()
            #expect(wgsl.parameters == glsl.parameters)
            #expect(wgsl.textures == glsl.textures)
            #expect(wgsl.usesTime == glsl.usesTime)
            #expect(Set(wgsl.sourceMap.values.map { "\($0.nodeID)/\($0.port ?? "")" }) == Set(glsl.sourceMap.values.map { "\($0.nodeID)/\($0.port ?? "")" }))
            #expect(!wgsl.source.contains("invalid shader identifier"))

            let module = try link(wgsl)
            let entry = try #require(module.entryPoints.first)
            let layouts = try WESLBackendCompiler.webGPUUniformBuffers(module, entryPoint: entry)
            let uniforms = try #require(layouts.first { Int($0.group) == ShaderGraphProgram.resourceSet && Int($0.binding) == ShaderGraphProgram.uniformBinding })
            // One aligned vec4 per parameter plus slot zero for time.
            #expect(uniforms.minimumByteSize == UInt64((glsl.parameters.count + 1) * 16))
            // The linker re-tokenizes with spaces, so compare without whitespace.
            let compact = module.wgsl.filter { !$0.isWhitespace }
            #expect(compact.contains("@binding(\(ShaderGraphProgram.firstTextureBinding))"))
            #expect(compact.contains("@binding(\(ShaderGraphProgram.samplerBinding))"))
        }

        @Test(arguments: ["flat3d", "directional_shadow_3d", "motion_3d"])
        func graphSplicesIntoTheSurfaceTemplates(_ name: String) throws {
            let program = try texturedGraph().compileWGSL()
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let shaders = root.appendingPathComponent("Sources/AdaCorePipelines/Assets/Shaders")
            let template = try String(contentsOf: shaders.appendingPathComponent("\(name).wesl"), encoding: .utf8)
            let generated = program.inserting(in: template)
            var featureSets = [["ADA_SHADER_GRAPH"]]
            if name == "flat3d" { featureSets.append(["ADA_SHADER_GRAPH", "ADA_HYBRID_REFLECTION", "ADA_DIFFUSE_SURFACE"]) }
            if name != "flat3d" { featureSets.append(["ADA_SHADER_GRAPH", "ADA_MORPH"]) }
            for features in featureSets {
                let module = try WESLHostCompiler.compile(
                    source: generated,
                    packageRoot: shaders,
                    features: Dictionary(uniqueKeysWithValues: features.map { ($0, true) }),
                    dependencies: ["ada_engine": root.appendingPathComponent("Sources/AdaRender/Assets/Shaders/WESL")]
                )
                #expect(Set(module.entryPoints.map(\.stage)) == ["vertex", "fragment"], "\(name), features: \(features)")
                #expect(module.wgsl.contains("ada_graph_evaluate"))
                _ = try WESLBackendCompiler.compile(module, to: .msl)
            }
        }

        @Test(arguments: ["sprite", "sprite_instanced"])
        func graphSplicesIntoTheSpriteTemplates(_ name: String) throws {
            let program = try ShaderGraph(target: .sprite, output: "output", nodes: [
                .init(id: "tint", operation: .parameter, type: .color, value: [1, 1, 1, 1], reference: "tint"),
                .init(id: "output", operation: .output, inputs: ["color": .init("tint")]),
            ]).compileWGSL()
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let assets = root.appendingPathComponent("Sources/AdaSprite/Assets")
            let template = try String(contentsOf: assets.appendingPathComponent("\(name).wesl"), encoding: .utf8)
            let generated = program.inserting(in: template)
            for features in [[], ["ADA_SHADER_GRAPH"]] as [[String]] {
                let module = try WESLHostCompiler.compile(
                    source: features.isEmpty ? template : generated,
                    packageRoot: assets,
                    features: Dictionary(uniqueKeysWithValues: features.map { ($0, true) }),
                    dependencies: ["ada_engine": root.appendingPathComponent("Sources/AdaRender/Assets/Shaders/WESL")]
                )
                #expect(Set(module.entryPoints.map(\.stage)) == ["vertex", "fragment"], "\(name), features: \(features)")
                #expect(module.wgsl.contains("ada_graph_evaluate") == !features.isEmpty)
                _ = try WESLBackendCompiler.compile(module, to: .msl)
            }
        }

        @Test func resourcesAndDefaultsDoNotChangeCompiledCode() throws {
            var graph = texturedGraph()
            let before = try graph.compileWGSL()
            graph.nodes[1].reference = "other.png"
            graph.nodes[3].value = [0, 0, 0, 1]
            graph.nodes.reverse()
            let after = try graph.compileWGSL()
            #expect(before.source == after.source)
            #expect(before.parameters != after.parameters)
            #expect(before.textures != after.textures)
        }
    }
#endif
