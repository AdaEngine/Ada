@testable import AdaRender
import Foundation
import Testing

@Suite("Generated shader graph functions", .serialized)
struct ShaderGraphProgramTests {
    @Test func validationRetainsNodeAndPortLocations() throws {
        var program = try graph().compileWGSL()
        try program.validateWGSL()
        let entry = try #require(program.sourceMap.first { $0.value.nodeID == "output" && $0.value.port == "color" })
        var source = program.source.components(separatedBy: "\n")
        source[entry.key - 1] = "ada_graph_result.color = missing_graph_color;"
        program = ShaderGraphProgram(
            target: program.target,
            renderSettings: program.renderSettings,
            source: source.joined(separator: "\n"),
            parameters: program.parameters,
            textures: program.textures,
            sourceMap: program.sourceMap,
            usesTime: program.usesTime,
            format: .wgsl
        )
        do {
            try program.validateWGSL()
            Issue.record("SAGA accepted an unknown Shader Graph value")
        } catch let error as ShaderGraphCompilationError {
            #expect(error.nodeID == "output")
            #expect(error.port == "color")
            #expect(error.message.contains("missing_graph_color"))
        }
    }

    private func graph() -> ShaderGraph {
        ShaderGraph(target: .sprite, output: "output", nodes: [
            .init(id: "uv", operation: .uv, type: .vector2),
            .init(id: "texture", operation: .texture, type: .texture2D, reference: "stone.png"),
            .init(id: "sample", operation: .sampleTexture, type: .vector4, inputs: ["texture": .init("texture"), "uv": .init("uv")]),
            .init(id: "tint", operation: .parameter, type: .color, value: [1, 1, 1, 1], reference: "tint; invalid shader identifier"),
            .init(id: "multiply", operation: .multiply, type: .color, inputs: ["a": .init("sample", port: "color"), "b": .init("tint")]),
            .init(id: "output", operation: .output, inputs: ["color": .init("multiply")])
        ])
    }

    @Test func resourcesAndDefaultsDoNotChangeCompiledCode() throws {
        var graph = graph()
        let before = try graph.compileWGSL()
        graph.nodes[1].reference = "other.png"
        graph.nodes[3].value = [0, 0, 0, 1]
        graph.nodes.reverse()
        let after = try graph.compileWGSL()
        #expect(before.source == after.source)
        #expect(before.parameters != after.parameters)
        #expect(before.textures != after.textures)
        #expect(!after.source.contains("invalid shader identifier"))
        #expect(after.parameters[0].slot == 1)
        #expect(after.textures[0].binding == ShaderGraphProgram.firstTextureBinding)
        #expect(!after.sourceMap.isEmpty)
    }

    @Test(arguments: [ShaderGraph.Target.sprite, .pbrSurface])
    func realCompilerAcceptsGeneratedFunctions(target: ShaderGraph.Target) throws {
        var graph = graph()
        graph.target = target
        if target == .pbrSurface { graph.nodes[5].inputs = ["baseColor": .init("multiply"), "emission": .init("sample", port: "rgb")] }
        let program = try graph.compileWGSL()
        let artifact = try ShaderGraphArchive.Fragment.bake(
            template: "graph_test",
            templateSource: """
                // ADA_GRAPH_SOURCE_MARKER
                @fragment fn main() -> @location(0) vec4f {
                    let surface = ada_graph_evaluate(vec2f(0.5));
                    return surface.color + vec4f(surface.emission, 0.0);
                }
                """,
            program: program,
            packageRoot: FileManager.default.temporaryDirectory,
            macros: []
        )
        #expect(artifact.entryPoint == "main")
        let reflection = artifact.reflection
        #expect(reflection.descriptorSets[ShaderGraphProgram.resourceSet].uniformsBuffers[ShaderGraphProgram.uniformBinding] != nil)
        #expect(reflection.descriptorSets[ShaderGraphProgram.resourceSet].sampledImages[ShaderGraphProgram.firstTextureBinding] != nil)
        #expect(reflection.descriptorSets[ShaderGraphProgram.samplerSet].samplers[ShaderGraphProgram.samplerBinding] != nil)
    }
}
