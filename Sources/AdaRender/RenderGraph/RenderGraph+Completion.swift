extension RenderGraph {
    /// Enqueues a fence after every current root node and its subgraphs on the
    /// graph's command queue. The callback runs only when that GPU work completes.
    /// Install after configuring the graph, before its first update.
    package mutating func addFrameCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        let predecessors = Array(nodes.keys)
        addNode(FrameCompletionNode(handler: handler))
        for predecessor in predecessors {
            addNodeEdge(from: predecessor, to: FrameCompletionNode.name)
        }
    }
}

private struct FrameCompletionNode: RenderNode {
    let handler: @Sendable () -> Void

    func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        let command = renderContext.commandQueue.makeCommandBuffer()
        command.label = "Frame completion fence"
        command.addCompletedHandler(handler)
        command.commit()
        return []
    }
}
