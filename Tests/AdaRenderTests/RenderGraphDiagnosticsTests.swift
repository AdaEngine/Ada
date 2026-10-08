import Testing
@_spi(Internal) import AdaECS
@testable import AdaRender
import Foundation
import Math

@Suite("Render graph diagnostics")
struct RenderGraphDiagnosticsTests {
    @Test("Snapshot describes nodes edges slots and subgraphs")
    func snapshotDescribesGraph() {
        var graph = RenderGraph(label: "Root")
        let entryNode = graph.addEntryNode(inputs: [
            RenderSlot(name: "view", kind: .entity)
        ])
        graph.addNode(PassthroughEntityNode())
        graph.addNode(EmptyRenderNode(), by: "End")
        graph.addSlotEdge(
            fromNode: entryNode,
            outputSlot: "view",
            toNode: PassthroughEntityNode.name,
            inputSlot: "view"
        )
        graph.addNodeEdge(from: PassthroughEntityNode.name, to: "End")

        var subgraph = RenderGraph(label: "Sub")
        subgraph.addNode(EmptyRenderNode(), by: "Sub.Empty")
        graph.addSubgraph(subgraph, name: "Sub")

        let snapshot = graph.makeSnapshot(includeSubgraphs: true)

        #expect(snapshot.label == "Root")
        #expect(snapshot.entryNode == RenderGraph.entryNodeName.rawValue)
        #expect(snapshot.nodes.contains { $0.label == PassthroughEntityNode.name.rawValue })
        #expect(snapshot.edges.contains { $0.kind == .slot && $0.outputSlot == "view" && $0.inputSlot == "view" })
        #expect(snapshot.edges.contains { $0.kind == .node && $0.toNode == "End" })
        #expect(snapshot.subgraphs.map(\.label) == ["Sub"])
        #expect(snapshot.issues.isEmpty)
    }

    @Test("Snapshot reports missing subgraph references")
    func snapshotReportsMissingSubgraph() {
        var graph = RenderGraph(label: "Root")
        graph.addNode(RunGraphNode(graphName: "Missing"), by: "RunMissing")

        let snapshot = graph.makeSnapshot(includeSubgraphs: true)

        #expect(snapshot.issues.contains { $0.code == "missing_subgraph" && $0.node == "RunMissing" })
    }

    @Test("Executor records node timings subgraphs and respects capacity")
    func executorRecordsFrames() async throws {
        let world = World(name: "RenderWorld")
        let entity = world.spawn("View") {}
        world.insertResource(TestEntityResource(entity: entity))

        var subgraph = RenderGraph(label: "Sub")
        subgraph.addNode(SourceEntityNode())
        subgraph.addNode(SinkEntityNode())
        subgraph.addSlotEdge(
            fromNode: SourceEntityNode.name,
            outputSlot: "view",
            toNode: SinkEntityNode.name,
            inputSlot: "view"
        )

        var graph = RenderGraph(label: "Root")
        graph.addNode(RunGraphNode(graphName: "Sub"), by: "RunSub")
        graph.addSubgraph(subgraph, name: "Sub")

        let diagnostics = RenderGraphDiagnostics(isEnabled: true, capacity: 3)
        let executor = RenderGraphExecutor()

        try await executor.execute(graph, renderDevice: TestRenderDevice(), in: world, diagnostics: diagnostics)
        try await executor.execute(graph, renderDevice: TestRenderDevice(), in: world, diagnostics: diagnostics)

        let records = diagnostics.recentFrames()
        #expect(records.count == 3)
        #expect(records.contains { $0.graphLabel == "Root" && $0.pendingSubgraphs == ["Sub"] })
        #expect(records.contains { $0.graphLabel == "Sub" && $0.executionOrder == [SourceEntityNode.name.rawValue, SinkEntityNode.name.rawValue] })
        #expect(records.allSatisfy { $0.durationMilliseconds >= 0 })
    }

    @Test("Executor records node errors before rethrowing")
    func executorRecordsErrors() async {
        let world = World(name: "RenderWorld")
        var graph = RenderGraph(label: "Root")
        graph.addNode(FailingRenderNode())
        let diagnostics = RenderGraphDiagnostics(isEnabled: true, capacity: 4)

        do {
            try await RenderGraphExecutor().execute(
                graph,
                renderDevice: TestRenderDevice(),
                in: world,
                diagnostics: diagnostics
            )
            Issue.record("Expected render graph execution to throw.")
        } catch {
            let records = diagnostics.recentFrames()
            #expect(records.count == 1)
            #expect(records.first?.error == TestRenderError.failed.localizedDescription)
            #expect(records.first?.nodes.first?.label == FailingRenderNode.name.rawValue)
        }
    }
}

private struct TestEntityResource: Resource {
    let entity: Entity
}

private struct SourceEntityNode: RenderNode {
    var outputResources: [RenderSlot] {
        [RenderSlot(name: "view", kind: .entity)]
    }

    func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let entity = context.world.getResource(TestEntityResource.self)?.entity else {
            return []
        }
        return [RenderSlotValue(name: "view", value: .entity(entity))]
    }
}

private struct SinkEntityNode: RenderNode {
    var inputResources: [RenderSlot] {
        [RenderSlot(name: "view", kind: .entity)]
    }

    func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        []
    }
}

private struct PassthroughEntityNode: RenderNode {
    var inputResources: [RenderSlot] {
        [RenderSlot(name: "view", kind: .entity)]
    }

    var outputResources: [RenderSlot] {
        [RenderSlot(name: "view", kind: .entity)]
    }

    func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        context.inputResources
    }
}

private enum TestRenderError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test render node failed."
    }
}

private struct FailingRenderNode: RenderNode {
    func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        throw TestRenderError.failed
    }
}

private final class TestRenderDevice: RenderDevice, @unchecked Sendable {
    func createBuffer(label: String?, length: Int, options: ResourceOptions) -> Buffer {
        TestBuffer(label: label, length: length)
    }

    func createBuffer(label: String?, bytes: UnsafeRawPointer, length: Int, options: ResourceOptions) -> Buffer {
        TestBuffer(label: label, length: length)
    }

    func createIndexBuffer(label: String?, format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> IndexBuffer {
        TestIndexBuffer(label: label, length: length, indexFormat: format)
    }

    func createVertexBuffer(label: String?, length: Int, binding: Int) -> VertexBuffer {
        TestVertexBuffer(label: label, length: length, binding: binding)
    }

    func compileShader(from shader: Shader) throws -> any CompiledShader {
        fatalError("Not used by render graph diagnostics tests.")
    }

    func createRenderPipeline(from descriptor: RenderPipelineDescriptor) -> RenderPipeline {
        fatalError("Not used by render graph diagnostics tests.")
    }

    func createSampler(from descriptor: SamplerDescriptor) -> Sampler {
        TestSampler(descriptor: descriptor)
    }

    func createUniformBuffer(length: Int, binding: Int) -> UniformBuffer {
        TestUniformBuffer(label: nil, length: length, binding: binding)
    }

    func createTexture(from descriptor: TextureDescriptor) -> GPUTexture {
        TestGPUTexture(size: SizeInt(width: descriptor.width, height: descriptor.height), label: descriptor.debugLabel)
    }

    func getImage(from texture: Texture) -> Image? {
        nil
    }

    func createCommandQueue() -> CommandQueue {
        TestCommandQueue()
    }

    @MainActor
    func createSwapchain(from window: WindowID) -> (any Swapchain)? {
        nil
    }
}

private class TestBuffer: Buffer, @unchecked Sendable {
    var label: String?
    let length: Int
    private let pointer: UnsafeMutableRawPointer

    init(label: String?, length: Int) {
        self.label = label
        self.length = length
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: max(length, 1), alignment: 1)
    }

    deinit {
        pointer.deallocate()
    }

    func setData(_ bytes: UnsafeMutableRawPointer, byteCount: Int, offset: Int) {}
    func contents() -> UnsafeMutableRawPointer { pointer }
    func unmap() {}
}

private final class TestIndexBuffer: TestBuffer, IndexBuffer, @unchecked Sendable {
    let indexFormat: IndexBufferFormat

    init(label: String?, length: Int, indexFormat: IndexBufferFormat) {
        self.indexFormat = indexFormat
        super.init(label: label, length: length)
    }
}

private final class TestVertexBuffer: TestBuffer, VertexBuffer, @unchecked Sendable {
    let binding: Int

    init(label: String?, length: Int, binding: Int) {
        self.binding = binding
        super.init(label: label, length: length)
    }
}

private final class TestUniformBuffer: TestBuffer, UniformBuffer, @unchecked Sendable {
    let binding: Int

    init(label: String?, length: Int, binding: Int) {
        self.binding = binding
        super.init(label: label, length: length)
    }
}

private final class TestSampler: Sampler {
    let descriptor: SamplerDescriptor

    init(descriptor: SamplerDescriptor) {
        self.descriptor = descriptor
    }
}

private final class TestGPUTexture: GPUTexture {
    let size: SizeInt
    var label: String?

    init(size: SizeInt, label: String?) {
        self.size = size
        self.label = label
    }

    func replaceRegion(_ region: RectInt, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int) {}
}

private final class TestCommandQueue: CommandQueue {
    func makeCommandBuffer() -> CommandBuffer {
        TestCommandBuffer()
    }
}

private final class TestCommandBuffer: CommandBuffer {
    var label: String?

    func beginRenderPass(_ desc: RenderPassDescriptor) -> RenderCommandEncoder {
        fatalError("Not used by render graph diagnostics tests.")
    }

    func beginBlitPass(_ desc: BlitPassDescriptor) -> BlitCommandEncoder {
        fatalError("Not used by render graph diagnostics tests.")
    }

    func commit() {}
    func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {}
}
