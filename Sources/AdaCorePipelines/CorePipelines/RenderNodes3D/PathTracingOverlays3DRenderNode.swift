import AdaECS
import AdaRender

/// Cosmetic shader graphs keep their original depth-tested appearance over traced surface lighting.
struct PathTracingOverlays3DRenderNode: RenderNode {
    static let name: RenderNodeLabel = "Main3D.PathTracingOverlays"
    private let geometry = Main3DRenderNode(pathTracingOverlaysOnly: true)
    init() {}
    func update(from world: World) { geometry.update(from: world) }
    func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        try await geometry.execute(context: &context, renderContext: renderContext)
    }
}
