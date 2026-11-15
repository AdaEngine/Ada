@testable import AdaRender
import Testing

@Suite("Shader Graph effects") struct ShaderGraphEffectTests {
    private static let operations: [ShaderGraph.Operation] = [
        .subtract, .divide, .power, .minimum, .maximum, .clamp, .saturate, .oneMinus, .sine, .cosine, .absolute, .fraction, .floor, .step, .smoothstep,
    ]

    @Test(arguments: operations) func mathNodesCompileWithScalarAndVectorInputs(_ operation: ShaderGraph.Operation) throws {
        for type in [ShaderGraph.ValueType.float, .vector2, .vector3, .vector4, .color] {
            var graph = ShaderGraph(target: .sprite, output: "output", nodes: [])
            var operationNode = ShaderGraph.Node(id: "effect", operation: operation, type: type)
            for port in graph.inputPorts(for: operationNode).keys {
                graph.nodes.append(.init(id: port, operation: .constant, value: [0.7]))
                operationNode.inputs[port] = .init(port)
            }
            graph.nodes.append(operationNode)
            graph.nodes.append(.init(id: "output", operation: .output, inputs: ["alpha": .init("effect", port: type == .float ? "value" : "x")]))
            try graph.compileWGSL().validateWGSL()
        }
    }

    @Test func animatedMaterialsAdvanceOnceAndManualTransportOwnsItsClock() throws {
        let graph = ShaderGraph(target: .sprite, output: "output", nodes: [.init(id: "time", operation: .time), .init(id: "output", operation: .output, inputs: ["alpha": .init("time")])])
        let material = try ShaderGraphMaterial(source: .init(graph: graph))
        #expect(material.program.usesTime)
        material.updateAutomaticTime(1)
        let first = material.valueRevision
        material.updateAutomaticTime(1)
        #expect(material.valueRevision == first)
        material.setTime(2)
        let manual = material.valueRevision
        material.updateAutomaticTime(3)
        #expect(material.valueRevision == manual)
        var clock = ShaderGraphClock()
        clock.advance(delta: 900_000)
        clock.advance(delta: 0.125)
        clock.advance(delta: .nan)
        #expect(clock.elapsed == 0.125)
    }

    @Test func proceduralNoiseAndExplicitVectorChannelsCompile() throws {
        let graph = ShaderGraph(
            target: .pbrSurface,
            output: "output",
            nodes: [
                .init(id: "x", operation: .constant, value: [-0.25]), .init(id: "uv", operation: .combine2, type: .vector2, inputs: ["x": .init("x"), "y": .init("x")]),
                .init(id: "noise", operation: .noise2D, inputs: ["uv": .init("uv")]),
                .init(id: "color", operation: .combine4, type: .vector4, inputs: ["x": .init("noise"), "y": .init("noise"), "z": .init("noise"), "w": .init("x")]),
                .init(id: "output", operation: .output, inputs: ["baseColor": .init("color", port: "color")]),
            ]
        )
        let program = try graph.compileWGSL()
        try program.validateWGSL()
        #expect(!program.usesTime)
        let material = try ShaderGraphMaterial(source: .init(graph: graph))
        material.setTime(1)
        material.updateAutomaticTime(2)
        #expect(material.valueRevision == 0)
    }
}
