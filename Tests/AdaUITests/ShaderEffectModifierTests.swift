//
//  ShaderEffectModifierTests.swift
//  AdaEngine
//

import AdaAssets
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaText
import AdaUtils
import Foundation
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

#if os(macOS)
@Suite(.serialized)
@MainActor
struct ShaderEffectMetalRenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_GOLDEN_SAGA"] == "1"))
    func shaderEffectPreservesProjectionForFollowingDraws() async throws {
        unsafe RenderEngine.configurations.preferredBackend = .saga
        try RenderEngine.setupRenderEngine()
        let device = unsafe RenderEngine.shared.renderDevice
        let target = RenderTexture(size: SizeInt(width: 96, height: 48), scaleFactor: 1, format: .bgra8)
        let viewport = Rect(x: 0, y: 0, width: 96, height: 48)

        let world = World(name: "UI shader effect")
        world.setSchedulers([.update])
        world.insertResource(RenderDeviceHandler(renderDevice: device))
        world.insertResource(RenderPipelines(configurator: TextPipeline()))
        world.insertResource(RenderPipelines(configurator: QuadPipeline()))
        world.insertResource(RenderPipelines(configurator: CirclePipeline()))
        world.insertResource(RenderPipelines(configurator: LinePipeline()))
        world.insertResource(RenderPipelines(configurator: LinearGradientPipeline()))
        world.insertResource(RenderPipelines(configurator: GlassPipeline()))
        world.insertResource(UIRenderPipelines(from: world))
        world.insertResource(RenderItems<UITransparentRenderItem>())
        world.insertResource(UIDrawPass())
        world.insertResource(UILayerDrawCache())
        world.insertResource(UIRenderBuildState())
        world.addSystem(UIRenderTesselationSystem.self)

        let context = UIGraphicsContext()
        let material = CustomMaterial(TestUIShaderMaterial())
        context.drawShaderEffect(Rect(x: 0, y: 0, width: 32, height: 32), material: material)
        context.drawRect(Rect(x: 48, y: 0, width: 32, height: 32), color: .red)
        var pending = PendingUIGraphicsContext()
        pending.graphicContexts.append(context)
        world.insertResource(pending)
        await world.runScheduler(.update)
        let items = try #require(world.getResource(RenderItems<UITransparentRenderItem>.self)).items
        try #require(items.count == 2)

        let commands = device.createCommandQueue().makeCommandBuffer()
        let pass = commands.beginRenderPass(RenderPassDescriptor(colorAttachments: [
            .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
        ]))
        let projection = Transform3D.createUIProjection(width: viewport.width, height: viewport.height)
        pass.setViewport(viewport)
        pass.setVertexBuffer(GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection), slot: GlobalBufferIndex.viewUniform)
        let view = Entity()
        for item in items {
            try UIDrawPass().render(with: pass, world: world, view: view, item: item)
        }
        pass.endRenderPass()
        commands.commit()

        let image = try #require(try await device.readImage(from: target))
        #expect(image.getPixel(x: 16, y: 16) != .black, "The effect must use the renderer's view projection")
        #expect(image.getPixel(x: 56, y: 16) == .red, "A shader effect must preserve projection for subsequent UI draws")
    }
}
#endif

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

