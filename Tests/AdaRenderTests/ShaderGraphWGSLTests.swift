#if canImport(AdaWGSLCompiler) && !os(WASI) && !os(Android)
    import AdaWGSLCompiler
    @testable import AdaRender
    import Foundation
    import Testing

    /// Generated WGSL must preserve the Shader Graph binding contract.
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

        @Test func cpuValidationLocatesAnInvalidGraphOutput() throws {
            let program = try texturedGraph().compileWGSL()
            try program.validateWGSL()
            let output = try #require(program.sourceMap.first { $0.value.nodeID == "output" && $0.value.port == "baseColor" })
            var lines = program.source.components(separatedBy: "\n")
            lines[output.key - 1] = "ada_graph_result.color = missing_graph_value;"
            let invalid = ShaderGraphProgram(
                target: program.target,
                renderSettings: program.renderSettings,
                source: lines.joined(separator: "\n"),
                parameters: program.parameters,
                textures: program.textures,
                sourceMap: program.sourceMap,
                usesTime: program.usesTime,
                format: .wgsl
            )
            do {
                try invalid.validateWGSL()
                Issue.record("SAGA accepted an unknown Shader Graph value")
            } catch let error as ShaderGraphCompilationError {
                #expect(error.nodeID == "output")
                #expect(error.port == "baseColor")
                #expect(error.message.contains("missing_graph_value"))
            }
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

        @Test func bindingsAndParameterSlotsMatchTheRuntimeContract() throws {
            let wgsl = try texturedGraph().compileWGSL()
            let parameter = try #require(wgsl.parameters.first)
            #expect(wgsl.parameters.count == 1)
            #expect(parameter.slot == 1)
            #expect(parameter.type == .color)
            #expect(parameter.defaultValue == [1, 1, 1, 1])
            let texture = try #require(wgsl.textures.first)
            #expect(wgsl.textures.count == 1)
            #expect(texture.path == "stone.png")
            #expect(texture.binding == ShaderGraphProgram.firstTextureBinding)
            #expect(wgsl.usesTime)
            let outputPorts = Set(wgsl.sourceMap.values.filter { $0.nodeID == "output" }.compactMap(\.port))
            #expect(outputPorts == ["baseColor", "emission", "alpha"])
            #expect(!wgsl.source.contains("invalid shader identifier"))

            let module = try link(wgsl)
            let entry = try #require(module.entryPoints.first)
            let layouts = try WESLBackendCompiler.webGPUUniformBuffers(module, entryPoint: entry)
            let uniforms = try #require(layouts.first { Int($0.group) == ShaderGraphProgram.resourceSet && Int($0.binding) == ShaderGraphProgram.uniformBinding })
            // One aligned vec4 per parameter plus slot zero for time.
            #expect(uniforms.minimumByteSize == UInt64((wgsl.parameters.count + 1) * 16))
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
