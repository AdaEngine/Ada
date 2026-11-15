//
//  ShaderEffectModifierTests.swift
//  AdaEngine
//

import AdaAssets
import AdaRender
import AdaUtils
import Math
import Testing
@testable import AdaPlatform
@testable import AdaUI

@MainActor
struct ShaderEffectModifierTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func backgroundPlacement_drawsShaderBeforeContent() {
        let material = CustomMaterial(TestUIShaderMaterial())
        let tester = ViewTester {
            Color.blue
                .shaderEffect(material, placement: .background)
        }

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)

        let commands = context.getDrawCommands()
        #expect(commands.count >= 2)
        #expect(commands.first?.isShaderEffectCommand == true)
        #expect(commands.dropFirst().contains { $0.isQuadCommand })
    }

    @Test
    func overlayPlacement_drawsShaderAfterContent() {
        let material = CustomMaterial(TestUIShaderMaterial())
        let tester = ViewTester {
            Color.blue
                .shaderEffect(material, placement: .overlay)
        }

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)

        let commands = context.getDrawCommands()
        #expect(commands.count >= 2)
        #expect(commands.first?.isQuadCommand == true)
        #expect(commands.last?.isShaderEffectCommand == true)
    }

    @Test
    func shaderEffect_usesViewBoundsTransform() {
        let material = CustomMaterial(TestUIShaderMaterial())
        let tester = ViewTester {
            Color.blue
                .shaderEffect(material)
        }
        .setSize(Size(width: 320, height: 180))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)

        guard case let .drawShaderEffect(transform, emittedMaterial)? = context.getDrawCommands().last else {
            Issue.record("Expected shader effect draw command.")
            return
        }

        #expect(emittedMaterial === material)
        #expect(transform == Rect(x: 0, y: 0, width: 320, height: 180).toTransform3D)
    }

    @Test
    func shaderEffectDrawData_reportsNonEmptyAndClears() {
        let material = CustomMaterial(TestUIShaderMaterial())
        let tessellator = UITessellator()
        var drawData = UIDrawData()
        let vertices = tessellator.tessellateShaderEffect(
            transform: Rect(x: 0, y: 0, width: 48, height: 24).toTransform3D
        )
        let indices = tessellator.generateQuadIndices(vertexOffset: 0)

        drawData.shaderEffectVertexBuffer.elements.append(contentsOf: vertices)
        drawData.shaderEffectIndexBuffer.elements.append(contentsOf: indices)
        drawData.shaderEffectBatches.append(
            UIDrawData.ShaderEffectBatch(
                material: material,
                indexOffset: 0,
                indexCount: indices.count
            )
        )

        #expect(drawData.isEmpty == false)

        drawData.clear()

        #expect(drawData.isEmpty)
        #expect(drawData.shaderEffectBatches.isEmpty)
    }
}

private struct TestUIShaderMaterial: UIShaderMaterial {
    static func shaderModule() throws -> ShaderModule? {
        try ShaderModule.createWESL(source: """
            import ada_engine::view::projectPosition;

            struct VertexOutput {
                @builtin(position) position: vec4f,
                @location(0) color: vec4f,
                @location(1) uv: vec2f,
            }

            @vertex fn testVertex(@location(0) position: vec4f, @location(1) color: vec4f, @location(2) uv: vec2f) -> VertexOutput {
                return VertexOutput(projectPosition(position), color, uv);
            }

            @fragment fn testFragment(input: VertexOutput) -> @location(0) vec4f {
                return vec4f(input.uv, 0.0, 1.0);
            }
            """)
    }

}

private extension UIGraphicsContext.DrawCommand {
    var isQuadCommand: Bool {
        if case .drawQuad = self {
            return true
        }
        return false
    }

    var isShaderEffectCommand: Bool {
        if case .drawShaderEffect = self {
            return true
        }
        return false
    }
}

