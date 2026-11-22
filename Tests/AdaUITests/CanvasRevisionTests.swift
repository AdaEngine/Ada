@_spi(Internal) @testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
@Suite("Synchronous Canvas drawing revisions")
struct CanvasRevisionTests {
    @Test("Revision changes refresh retained commands without layout or async observation")
    func revisionRefreshesDrawing() throws {
        var revision: UInt64 = 0
        var draws = 0
        let container = UIContainerView(rootView: Canvas(drawingRevision: { revision }) { context, _ in
            draws += 1
            context.drawRect(Rect(x: Float(revision), y: 0, width: 10, height: 10), color: .red)
        })
        container.frame = Rect(x: 0, y: 0, width: 200, height: 100)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        func draw() throws -> (UInt64, Transform3D) {
            let context = UIGraphicsContext()
            container.viewTree.rootNode.draw(with: context)
            context.commitDraw()
            let commands = context.getDrawCommands()
            let version = try #require(commands.compactMap { command -> UInt64? in
                if case let .beginLayer(_, version, true) = command {
                    return version
                }
                return nil
            }.first)
            let transform = try #require(commands.compactMap { command -> Transform3D? in
                if case let .drawQuad(transform, _, _) = command {
                    return transform
                }
                return nil
            }.first)
            return (version, transform)
        }

        let first = try draw()
        #expect(try draw().0 == first.0)
        #expect(draws == 1)
        revision = 50
        let second = try draw()
        #expect(second.0 > first.0)
        #expect(second.1.origin.x - first.1.origin.x == 50)
        #expect(draws == 2)
        #expect(try draw().0 == second.0)
        #expect(draws == 2)

        container.frame.size = Size(width: 300, height: 150)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        #expect(try draw().0 > second.0)
        #expect(draws == 3)
    }

    @Test
    func revisionSchedulesDisplayWithoutReplacingMountedCanvas() throws {
        var revision: UInt64 = 0
        var draws = 0
        func paint(_ context: inout UIGraphicsContext) {
            context.drawRect(Rect(x: 0, y: 0, width: 50, height: 30), color: .white)
            context.drawRect(Rect(x: 5, y: 5, width: 8, height: 8), color: .blue)
            context.drawRect(Rect(x: 25, y: 5, width: 8, height: 8), color: revision == 0 ? .red : .green)
        }
        let host = ViewTester {
            Canvas(drawingRevision: { revision }) { context, _ in
                draws += 1
                paint(&context)
            }
        }.setSize(Size(width: 100, height: 80)).performLayout().containerView
        let node = host.viewTree.rootNode.contentNode
        let originalFrame = node.frame

        func frame() -> [Quad] {
            let context = UIGraphicsContext()
            host.draw(in: host.bounds, with: context)
            context.commitDraw()
            return quads(in: context)
        }

        let before = frame()
        try #require(before.count == 3)
        _ = host.consumeNeedsDisplay()
        host.update(0)
        #expect(!host.needsDisplay)

        UILayoutDebugCounters.isEnabled = true
        UILayoutDebugCounters.reset()
        defer { UILayoutDebugCounters.isEnabled = false }
        revision += 1
        host.update(0)
        revision += 1
        host.update(0)
        try #require(host.consumeNeedsDisplay(), "Canvas revision must request a frame")
        #expect(draws == 1)
        #expect(host.viewTree.rootNode.contentNode === node)
        #expect(node.frame == originalFrame)
        host.layoutIfNeeded()
        #expect(UILayoutDebugCounters.snapshot.layoutPasses == 0)
        #expect(UILayoutDebugCounters.snapshot.contentInvalidations == 0)
        #expect(UILayoutDebugCounters.snapshot.rebuilds == 0)

        let after = frame()
        try #require(after.count == 3)
        #expect(Array(after.prefix(2)) == Array(before.prefix(2)))
        #expect(after[2].color == .green)
        #expect(after[2].transform == before[2].transform)
        #expect(draws == 2)
        #expect(frame() == after)
        #expect(draws == 2)
        host.update(0)
        #expect(!host.needsDisplay)
    }

    private struct Quad: Equatable {
        let transform: Transform3D
        let color: Color
    }

    private func quads(in context: UIGraphicsContext) -> [Quad] {
        context.getDrawCommands().compactMap { command in
            guard case let .drawQuad(transform, _, color) = command else {
                return nil
            }
            return Quad(transform: transform, color: color)
        }
    }
}
