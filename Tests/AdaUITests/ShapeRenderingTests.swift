@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct ShapeRenderingTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func graphicsContext_fillPath_recordsFillCommand() {
        var path = Path()
        path.addRect(Rect(x: 0, y: 0, width: 40, height: 20))

        let context = makeContext { context in
            context.fill(path, with: .red)
        }

        guard let command = context.getDrawCommands().first else {
            Issue.record("Expected draw command for filled path.")
            return
        }

        guard case let .drawPath(_, transform, mode) = command else {
            Issue.record("Expected first command to be drawPath.")
            return
        }

        guard case let .fill(color) = mode else {
            Issue.record("Expected path drawing mode to be fill.")
            return
        }

        #expect(transform == .identity)
        #expect(color == .red)
    }

    @Test
    func graphicsContext_strokePath_recordsStrokeCommand() {
        var path = Path()
        path.addRect(Rect(x: 0, y: 0, width: 30, height: 30))
        let style = StrokeStyle(lineWidth: 3)

        let context = makeContext { context in
            context.stroke(path, with: .blue, style: style)
        }

        guard let command = context.getDrawCommands().first else {
            Issue.record("Expected draw command for stroked path.")
            return
        }

        guard case let .drawPath(_, transform, mode) = command else {
            Issue.record("Expected first command to be drawPath.")
            return
        }

        guard case let .stroke(color, recordedStyle) = mode else {
            Issue.record("Expected path drawing mode to be stroke.")
            return
        }

        #expect(transform == .identity)
        #expect(color == .blue)
        #expect(recordedStyle == style)
    }

    @Test
    func graphicsContext_fillPath_preservesCurrentTransform() {
        var path = Path()
        path.addRect(Rect(x: 0, y: 0, width: 20, height: 10))

        let context = makeContext { context in
            context.translateBy(x: 24, y: -18)
            context.fill(path, with: .red)
        }

        guard let command = context.getDrawCommands().first else {
            Issue.record("Expected draw command for transformed filled path.")
            return
        }

        guard case let .drawPath(_, transform, .fill(color)) = command else {
            Issue.record("Expected transformed drawPath fill command.")
            return
        }

        #expect(transform == Transform3D(translation: [24, -18, 0]))
        #expect(color == .red)
    }

    @Test
    func graphicsContext_clipPath_recordsPushAndPopCommands() {
        var path = Path()
        path.addRect(Rect(x: 0, y: 0, width: 20, height: 20))

        let context = makeContext { context in
            context.clip(to: path) { clipped in
                clipped.drawRect(Rect(x: 0, y: 0, width: 40, height: 40), color: .red)
            }
        }

        let commands = context.getDrawCommands()
        guard commands.count == 3 else {
            Issue.record("Expected push clip path, draw command, and pop clip path.")
            return
        }

        guard case let .pushClipPath(recordedPath, transform) = commands[0] else {
            Issue.record("Expected first command to push a clip path.")
            return
        }

        #expect(!recordedPath.isEmpty)
        #expect(transform == .identity)

        guard case .drawQuad = commands[1] else {
            Issue.record("Expected clipped body to draw between push and pop.")
            return
        }

        guard case .popClipPath = commands[2] else {
            Issue.record("Expected final command to pop the clip path.")
            return
        }
    }

    @Test
    func tessellator_fillRectProducesTriangleGeometry() {
        var path = Path()
        path.addRect(Rect(x: 0, y: 0, width: 100, height: 60))

        let result = UITessellator().tessellatePathFill(
            path,
            color: .green,
            transform: .identity
        )

        #expect(result.vertices.count == 4)
        #expect(result.indices.count == 6)
        #expect(result.vertices.allSatisfy { $0.color == .green })
        #expect(result.vertices.map(\.position.y).min() == -60)
        #expect(result.vertices.map(\.position.y).max() == 0)
    }

    @Test
    func tessellator_clipsQuadGeometryAgainstMaskPolygon() {
        let clipPolygon = [
            Vector2(0, 0),
            Vector2(50, 0),
            Vector2(50, -100),
            Vector2(0, -100)
        ]

        let result = UITessellator().tessellateClippedQuad(
            transform: Rect(x: 0, y: 0, width: 100, height: 100).toTransform3D,
            texture: nil,
            color: .red,
            textureIndex: 0,
            clipPolygons: [clipPolygon]
        )

        #expect(!result.vertices.isEmpty)
        #expect(!result.indices.isEmpty)
        #expect(result.vertices.map(\.position.x).min() == 0)
        #expect(result.vertices.map(\.position.x).max() == 50)
        #expect(result.vertices.map(\.position.y).min() == -100)
        #expect(result.vertices.map(\.position.y).max() == 0)
    }

    @Test
    func tessellator_preservesQuadFullyInsideMaskPolygon() {
        let clipPolygon = [
            Vector2(-10, 10),
            Vector2(110, 10),
            Vector2(110, -110),
            Vector2(-10, -110)
        ]

        let result = UITessellator().tessellateClippedQuad(
            transform: Rect(x: 0, y: 0, width: 100, height: 100).toTransform3D,
            texture: nil,
            color: .red,
            textureIndex: 0,
            clipPolygons: [clipPolygon]
        )

        #expect(result.vertices.count == 4)
        #expect(result.indices.count == 6)
    }

    @Test
    func tessellator_doesNotFastAcceptNonRectangularClipBounds() {
        let clipPolygon = [
            Vector2(50, 0),
            Vector2(100, -50),
            Vector2(50, -100),
            Vector2(0, -50)
        ]

        let result = UITessellator().tessellateClippedQuad(
            transform: Rect(x: 10, y: 10, width: 80, height: 80).toTransform3D,
            texture: nil,
            color: .red,
            textureIndex: 0,
            clipPolygons: [clipPolygon]
        )

        #expect(result.vertices.count == 8)
        #expect(result.indices.count == 18)
    }

    @Test
    func tessellator_rejectsQuadFullyOutsideMaskPolygon() {
        let clipPolygon = [
            Vector2(200, 0),
            Vector2(300, 0),
            Vector2(300, -100),
            Vector2(200, -100)
        ]

        let result = UITessellator().tessellateClippedQuad(
            transform: Rect(x: 0, y: 0, width: 100, height: 100).toTransform3D,
            texture: nil,
            color: .red,
            textureIndex: 0,
            clipPolygons: [clipPolygon]
        )

        #expect(result.vertices.isEmpty)
        #expect(result.indices.isEmpty)
    }

    @Test
    func tessellator_strokeCirclePreservesColorAndLineWidth() {
        let path = CircleShape().path(in: Rect(x: 0, y: 0, width: 40, height: 40))

        let result = UITessellator().tessellatePathStroke(
            path,
            lineWidth: 3,
            color: .mint,
            transform: .identity
        )

        #expect(!result.vertices.isEmpty)
        #expect(!result.indices.isEmpty)
        #expect(result.vertices.allSatisfy { $0.color == .mint && $0.lineWidth == 3 })
        #expect(result.vertices.map(\.position.y).min() ?? 1 < 0)
    }

    @Test
    func filledRectangleViewProducesFillPathCommand() {
        let command = pathCommand(for: RectangleShape().fill(Color.red))

        guard case let (_, _, .fill(color))? = command else {
            Issue.record("Expected rendered shape to use fill mode.")
            return
        }

        #expect(color == .red)
    }

    @Test
    func strokedCircleViewProducesStrokePathCommand() {
        let command = pathCommand(for: CircleShape().stroke(Color.blue, lineWidth: 3))

        guard case let (_, _, .stroke(color, style))? = command else {
            Issue.record("Expected rendered shape to use stroke mode.")
            return
        }

        #expect(color == .blue)
        #expect(style.lineWidth == 3)
    }

    @Test
    func backgroundFilledShape_usesLocalPathGeometryAndViewTransform() {
        let tester = ViewTester {
            Text("Shape")
                .background {
                    RectangleShape()
                        .fill(Color.red)
                        .accessibilityIdentifier("bg-shape")
                }
        }
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)

        guard let (path, transform, mode) = firstPathCommand(in: context) else {
            Issue.record("Expected background shape drawPath command.")
            return
        }

        guard case let .fill(color) = mode, color == .red else {
            Issue.record("Expected background shape fill mode.")
            return
        }

        var firstPoint: Vector2?
        path.forEach { element in
            guard firstPoint == nil else { return }
            if case let .move(to: point) = element {
                firstPoint = point
            }
        }

        #expect(firstPoint == Vector2.zero)
        #expect(transform != .identity)
    }

    @Test
    func maskShapeModifier_wrapsContentDrawingInClipPath() {
        let tester = ViewTester {
            Color.red
                .frame(width: 80, height: 80)
                .mask(RoundedRectangleShape(cornerRadius: 12))
        }
        .setSize(Size(width: 120, height: 120))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.draw(
            in: Rect(origin: .zero, size: tester.containerView.frame.size),
            with: context
        )

        let commands = context.getDrawCommands()
        guard let pushIndex = commands.firstIndex(where: {
            if case .pushClipPath = $0 { return true }
            return false
        }) else {
            Issue.record("Expected mask modifier to push a clip path.")
            return
        }

        guard let drawIndex = commands.firstIndex(where: {
            if case .drawQuad = $0 { return true }
            return false
        }) else {
            Issue.record("Expected masked content to draw a quad.")
            return
        }

        guard let popIndex = commands.firstIndex(where: {
            if case .popClipPath = $0 { return true }
            return false
        }) else {
            Issue.record("Expected mask modifier to pop the clip path.")
            return
        }

        #expect(pushIndex < drawIndex)
        #expect(drawIndex < popIndex)
    }

    @Test
    func rectangleMask_usesRectangularClipFastPath() {
        let tester = ViewTester {
            Color.red
                .frame(width: 80, height: 80)
                .mask(RectangleShape())
        }
        .setSize(Size(width: 120, height: 120))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.draw(
            in: Rect(origin: .zero, size: tester.containerView.frame.size),
            with: context
        )

        let commands = context.getDrawCommands()
        #expect(commands.contains { command in
            if case .pushClipRect = command { return true }
            return false
        })
        #expect(!commands.contains { command in
            if case .pushClipPath = command { return true }
            return false
        })
    }

    @Test
    func transformedClipRect_appliesTranslationAndFallsBackForRotation() throws {
        var translatedContext = UIGraphicsContext()
        translatedContext.translateBy(x: 30, y: -40)

        let didPushTranslatedClip = translatedContext.pushTransformedClipRect(Rect(x: 0, y: 0, width: 80, height: 60))
        #expect(didPushTranslatedClip)
        let translatedCommand = try #require(translatedContext.getDrawCommands().first)
        guard case let .pushClipRect(rect) = translatedCommand else {
            Issue.record("Expected a rectangular clip command.")
            return
        }
        #expect(rect == Rect(x: 30, y: 40, width: 80, height: 60))

        var rotatedContext = UIGraphicsContext()
        rotatedContext.rotate(by: .degrees(45))
        let didPushRotatedClip = rotatedContext.pushTransformedClipRect(Rect(x: 0, y: 0, width: 80, height: 60))
        #expect(!didPushRotatedClip)
        #expect(rotatedContext.getDrawCommands().isEmpty)
    }

    private func makeContext(
        _ configure: (inout UIGraphicsContext) -> Void
    ) -> UIGraphicsContext {
        var context = UIGraphicsContext()
        configure(&context)
        return context
    }

    private func pathCommand<Content: View>(
        for rootView: Content
    ) -> (Path, Transform3D, UIGraphicsContext.PathDrawingMode)? {
        let tester = ViewTester(rootView: rootView)
            .setSize(Size(width: 120, height: 120))
            .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.draw(
            in: Rect(origin: .zero, size: tester.containerView.frame.size),
            with: context
        )

        return firstPathCommand(in: context)
    }

    private func firstPathCommand(
        in context: UIGraphicsContext
    ) -> (Path, Transform3D, UIGraphicsContext.PathDrawingMode)? {
        for command in context.getDrawCommands() {
            if case let .drawPath(path, transform, mode) = command {
                return (path, transform, mode)
            }
        }

        return nil
    }
}
