import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaCorePipelines
import AdaInput
import AdaUtils
import Math

@MainActor
struct LiquidGlassTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func regularClearAndIdentityExposeLiquidGlassDefaults() {
        let regular = Glass.regular
        #expect(regular.isInteractive)
        #expect(regular.interactiveScale == 1.08)
        #expect(regular.stretchStrength == 0.5)
        #expect(regular.cornerRoundnessExponent == 4.8)
        #expect(regular.blurRadius == 14.0)
        #expect(regular.glassThickness == 6.0)
        #expect(regular.refractiveIndex == 1.10)
        #expect(regular.dispersionStrength == 0.0)
        #expect(regular.fresnelIntensity == 0.52)
        #expect(regular.glareIntensity == 0.30)
        #expect(regular.tintColor == Color(red: 0.97, green: 0.985, blue: 1.0, alpha: 0.07))

        let interaction = Glass.interaction
        #expect(interaction.blurRadius == 15.5)
        #expect(interaction.glassTintStrength == 1.0)
        #expect(interaction.fresnelIntensity == 0.96)
        #expect(interaction.glareIntensity == 1.0)
        #expect(interaction.tintColor == Color(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16))

        let clear = Glass.clear
        #expect(clear.blurRadius == 2.5)
        #expect(clear.glassThickness == 22.0)
        #expect(clear.dispersionStrength == 0.0)
        #expect(clear.fresnelIntensity == 0.38)
        #expect(clear.glareIntensity == 0.28)
        #expect(clear.tintColor == Color(red: 0.98, green: 0.99, blue: 1.0, alpha: 0.03))

        let identity = Glass.identity
        #expect(identity.blurRadius == 0.0)
        #expect(identity.glassTintStrength == 0.0)
        #expect(identity.opacity == 0.0)
        #expect(identity.glassThickness == 0.0)
        #expect(identity.dispersionStrength == 0.0)
        #expect(identity.fresnelIntensity == 0.0)
        #expect(identity.glareIntensity == 0.0)
        #expect(identity.tintColor == .clear)
    }

    @Test
    func fluentSettersOnlyChangeTargetValues() {
        let base = Glass.regular
        let updated = base
            .blurRadius(18.0)
            .glassTintStrength(0.33)
            .edgeShadowStrength(0.05)
            .cornerRoundnessExponent(5.5)
            .glassThickness(52.0)
            .refractiveIndex(1.2)
            .dispersionStrength(0.44)
            .fresnelDistanceRange(340.0)
            .fresnelIntensity(0.91)
            .fresnelEdgeSharpness(0.4)
            .glareDistanceRange(220.0)
            .glareAngleConvergence(1.4)
            .glareOppositeSideBias(0.8)
            .glareIntensity(0.67)
            .glareEdgeSharpness(0.3)
            .glareDirectionOffset(0.42)
            .tint(.mint.opacity(0.5))

        #expect(updated.blurRadius == 18.0)
        #expect(updated.glassTintStrength == 0.33)
        #expect(updated.edgeShadowStrength == 0.05)
        #expect(updated.cornerRoundnessExponent == 5.5)
        #expect(updated.glassThickness == 52.0)
        #expect(updated.refractiveIndex == 1.2)
        #expect(updated.dispersionStrength == 0.44)
        #expect(updated.fresnelDistanceRange == 340.0)
        #expect(updated.fresnelIntensity == 0.91)
        #expect(updated.fresnelEdgeSharpness == 0.4)
        #expect(updated.glareDistanceRange == 220.0)
        #expect(updated.glareAngleConvergence == 1.4)
        #expect(updated.glareOppositeSideBias == 0.8)
        #expect(updated.glareIntensity == 0.67)
        #expect(updated.glareEdgeSharpness == 0.3)
        #expect(updated.glareDirectionOffset == 0.42)
        #expect(updated.tintColor == .mint.opacity(0.5))

        #expect(base.blurRadius != updated.blurRadius)
        #expect(base.glassThickness != updated.glassThickness)
        #expect(base.glareDirectionOffset != updated.glareDirectionOffset)
        #expect(base.cornerRadius == updated.cornerRadius)
        #expect(base.opacity == updated.opacity)
    }

    @Test
    func tessellatorPacksAdvancedLiquidGlassParametersIntoVertices() throws {
        let config = Glass.regular
            .blurRadius(11.0)
            .glassTintStrength(0.61)
            .glassThickness(42.0)
            .refractiveIndex(1.18)
            .dispersionStrength(0.27)
            .edgeShadowStrength(0.01)
            .fresnelDistanceRange(310.0)
            .fresnelIntensity(0.55)
            .fresnelEdgeSharpness(0.12)
            .glareDistanceRange(205.0)
            .glareAngleConvergence(0.88)
            .glareOppositeSideBias(1.31)
            .glareIntensity(0.47)
            .glareEdgeSharpness(0.16)
            .glareDirectionOffset(-0.21)
            .tint(.orange.opacity(0.4))

        let tessellator = UITessellator()
        let vertices = tessellator.tessellateGlassQuad(
            transform: .identity,
            halfSize: Vector2(120, 36),
            configuration: config,
            scaleFactor: 2.0
        )

        #expect(vertices.count == 4)

        let first = try #require(vertices.first)
        #expect(first.color == .orange.opacity(0.4))
        #expect(first.glassParams0 == Vector4(11.0, config.cornerRadius, 0.61, 0.01))
        #expect(first.glassParams1 == Vector4(config.cornerRoundnessExponent, 42.0, 1.18, 0.27))
        #expect(first.glassParams2 == Vector4(310.0, 0.55, 0.12, 205.0))
        #expect(first.glassParams3 == Vector4(0.88, 1.31, 0.47, 0.16))
        #expect(first.glassInfo0 == Vector4(120.0, 36.0, 2.0, config.opacity))
        #expect(first.glassInfo1 == Vector4(-0.21, 0.0, 0.0, 0.0))
    }

    @Test
    func identityGlassDoesNotEmitGlassDrawCommand() {
        let tester = ViewTester {
            Text("Glass")
                .glassEffect(.identity, in: .rect(cornerRadius: 8))
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: context)

        #expect(!context.getDrawCommands().containsGlassDraw)
        #expect(context.getDrawCommands().containsTextDraw)
    }

    @Test
    func regularGlassKeepsTextDrawAfterGlassCommand() {
        let tester = ViewTester {
            Text("Glass")
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: context)
        let commands = context.getDrawCommands()

        let glassIndex = commands.firstIndexOfGlassDraw
        let textIndex = commands.firstIndexOfTextDraw

        #expect(glassIndex != nil)
        #expect(textIndex != nil)
        if let glassIndex, let textIndex {
            #expect(glassIndex < textIndex)
        }
    }

    @Test
    func interactiveGlassScalesWhilePressed() throws {
        let tester = ViewTester {
            Text("Glass")
                .frame(width: 120, height: 44)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        let initialContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: initialContext)
        let initialTransform = try #require(initialContext.getDrawCommands().glassTransforms.first)
        let hitNode = tester.click(at: Point(100, 50))
        #expect(hitNode is TextViewNode)
        tester.containerView.onMouseEvent(MouseEvent(
            window: .empty,
            button: .left,
            mousePosition: Point(100, 50),
            phase: .began,
            modifierKeys: [],
            time: 0
        ))

        let pressedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: pressedContext)
        let pressedTransform = try #require(pressedContext.getDrawCommands().glassTransforms.first)

        #expect(pressedTransform.x.x > initialTransform.x.x)
        #expect(pressedTransform.y.y > initialTransform.y.y)

        tester.containerView.onMouseEvent(MouseEvent(
            window: .empty,
            button: .left,
            mousePosition: Point(100, 50),
            phase: .ended,
            modifierKeys: [],
            time: 0.1
        ))
        for _ in 0..<120 {
            tester.containerView.update(1 / 60)
        }

        let releasedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: releasedContext)
        let releasedTransform = try #require(releasedContext.getDrawCommands().glassTransforms.first)

        #expect(releasedTransform.x.x == initialTransform.x.x)
        #expect(releasedTransform.y.y == initialTransform.y.y)
    }

    @Test
    func navigationButtonGlassStretchesWithCapturedTouch() throws {
        var actionCount = 0
        let tester = ViewTester {
            Button("Back") { actionCount += 1 }
                .buttonStyle(NavigationBarButtonStyle())
        }
        .setSize(Size(width: 220, height: 120))
        .performLayout()

        let initialContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: initialContext)
        let initialTransform = try #require(initialContext.getDrawCommands().glassTransforms.first)
        let navigationGlass = try #require(initialContext.getDrawCommands().glassConfigurations.first)
        #expect(navigationGlass.stretchStrength == 1)

        let start = Point(110, 60)
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: start, phase: .began, time: 0)])

        let pressedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: pressedContext)
        let pressedTransform = try #require(pressedContext.getDrawCommands().glassTransforms.first)

        let dragged = Point(140, 60)
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: dragged, phase: .moved, time: 0.1)])

        let draggedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: draggedContext)
        let draggedTransform = try #require(draggedContext.getDrawCommands().glassTransforms.first)
        #expect(draggedTransform.x.x > pressedTransform.x.x * 1.2)

        let diagonal = Point(140, 85)
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: diagonal, phase: .moved, time: 0.15)])
        let diagonalContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: diagonalContext)
        let diagonalTransform = try #require(diagonalContext.getDrawCommands().glassTransforms.first)
        #expect(diagonalTransform != draggedTransform)
        #expect(abs(diagonalTransform.x.y) > 0.01)

        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: diagonal, phase: .ended, time: 0.2)])
        #expect(actionCount == 0)

        let releaseContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: releaseContext)
        let releaseTransform = try #require(releaseContext.getDrawCommands().glassTransforms.first)
        #expect(releaseTransform != initialTransform)

        tester.containerView.update(1 / 60)
        let settlingContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: settlingContext)
        let settlingTransform = try #require(settlingContext.getDrawCommands().glassTransforms.first)
        #expect(settlingTransform != releaseTransform)
        #expect(settlingTransform != initialTransform)

        for _ in 0..<119 {
            tester.containerView.update(1 / 60)
        }
        let releasedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: releasedContext)
        let releasedTransform = try #require(releasedContext.getDrawCommands().glassTransforms.first)
        #expect(abs(releasedTransform.x.x - initialTransform.x.x) < 0.001)

        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: start, phase: .began, time: 1)])
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: start, phase: .ended, time: 1.1)])
        #expect(actionCount == 1)
    }

    @Test
    func navigationButtonGlassFollowsMouseWithoutClickingOnDrag() throws {
        var actionCount = 0
        let tester = ViewTester {
            Button("Back") { actionCount += 1 }
                .buttonStyle(NavigationBarButtonStyle())
        }
        .setSize(Size(width: 220, height: 120))
        .performLayout()

        let initialContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: initialContext)
        let initialTransform = try #require(initialContext.getDrawCommands().glassTransforms.first)

        let start = Point(110, 60)
        let dragged = Point(140, 80)
        tester.sendMouseEvent(at: start, button: .left, phase: .began)
        tester.sendMouseEvent(at: dragged, button: .left, phase: .changed)

        let draggedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: draggedContext)
        let draggedTransform = try #require(draggedContext.getDrawCommands().glassTransforms.first)
        #expect(draggedTransform != initialTransform)
        #expect(abs(draggedTransform.x.y) > 0.01)

        tester.sendMouseEvent(at: dragged, button: .left, phase: .ended)
        #expect(actionCount == 0)

        for _ in 0..<120 {
            tester.containerView.update(1 / 60)
        }
        let releasedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: releasedContext)
        let releasedTransform = try #require(releasedContext.getDrawCommands().glassTransforms.first)
        #expect(abs(releasedTransform.x.x - initialTransform.x.x) < 0.001)

        tester.sendMouseEvent(at: start, button: .left, phase: .began)
        tester.sendMouseEvent(at: start, button: .left, phase: .ended)
        #expect(actionCount == 1)
    }

    @Test
    func ordinaryGlassScalesAndLimitsLongDrag() throws {
        let tester = ViewTester {
            Text("Glass")
                .frame(width: 64, height: 48)
                .glassEffect(.regular)
        }
        .setSize(Size(width: 200, height: 120))
        .performLayout()

        let initialContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: initialContext)
        let initialTransform = try #require(initialContext.getDrawCommands().glassTransforms.first)

        let start = Point(100, 60)
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: start, phase: .began, time: 0)])
        let pressedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: pressedContext)
        let pressedTransform = try #require(pressedContext.getDrawCommands().glassTransforms.first)
        #expect(pressedTransform.x.x > initialTransform.x.x)

        let farAway = Point(4_000, 4_000)
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: farAway, phase: .moved, time: 0.1)])
        let draggedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: draggedContext)
        let draggedTransform = try #require(draggedContext.getDrawCommands().glassTransforms.first)
        #expect(abs(draggedTransform.w.x - initialTransform.w.x) < 150)
        #expect(abs(draggedTransform.w.y - initialTransform.w.y) < 150)
        #expect(draggedTransform.x.x < initialTransform.x.x * 1.5)

        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: farAway, phase: .ended, time: 0.2)])
        for _ in 0..<120 {
            tester.containerView.update(1 / 60)
        }
        let releasedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: releasedContext)
        let releasedTransform = try #require(releasedContext.getDrawCommands().glassTransforms.first)
        #expect(abs(releasedTransform.x.x - initialTransform.x.x) < 0.001)
    }

    @Test
    func glassStretchStrengthTunesDragWithoutChangingPressScale() throws {
        #expect(Glass.regular.stretchStrength(-1).stretchStrength == 0)
        #expect(Glass.regular.stretchStrength(2).stretchStrength == 1)

        func stretchedTransform(strength: Float) throws -> Transform3D {
            let tester = ViewTester {
                Text("Glass")
                    .frame(width: 64, height: 48)
                    .glassEffect(.regular.stretchStrength(strength))
            }
            .setSize(Size(width: 200, height: 120))
            .performLayout()

            tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: Point(100, 60), phase: .began, time: 0)])
            tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: Point(135, 60), phase: .moved, time: 0.1)])
            let context = UIGraphicsContext()
            tester.containerView.viewTree.renderGraph(renderContext: context)
            return try #require(context.getDrawCommands().glassTransforms.first)
        }

        let noStretch = try stretchedTransform(strength: 0)
        let reduced = try stretchedTransform(strength: 0.25)
        let regular = try stretchedTransform(strength: 0.5)
        let full = try stretchedTransform(strength: 1)
        #expect(noStretch.x.x > 1)
        #expect(noStretch.x.x < reduced.x.x)
        #expect(reduced.x.x < regular.x.x)
        #expect(regular.x.x < full.x.x)
    }

    @Test
    func glassAroundButtonRespondsWithoutStealingItsAction() throws {
        var actionCount = 0
        let tester = ViewTester {
            Button("Open") { actionCount += 1 }
                .frame(width: 120, height: 44)
                .glassEffect(.regular)
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        let initialContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: initialContext)
        let initialTransform = try #require(initialContext.getDrawCommands().glassTransforms.first)

        let point = Point(100, 50)
        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .began, time: 0)])
        let pressedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: pressedContext)
        let pressedTransform = try #require(pressedContext.getDrawCommands().glassTransforms.first)
        #expect(pressedTransform.x.x > initialTransform.x.x)

        tester.containerView.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .ended, time: 0.1)])
        #expect(actionCount == 1)
    }

    @Test
    func explicitlyNonInteractiveGlassRemainsStatic() throws {
        let tester = ViewTester {
            Text("Glass")
                .frame(width: 120, height: 44)
                .glassEffect(.regular.interactive(false), in: .rect(cornerRadius: 8))
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()

        let initialContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: initialContext)
        let initialTransform = try #require(initialContext.getDrawCommands().glassTransforms.first)

        let hitNode = tester.sendMouseEvent(at: Point(100, 50), button: .left, phase: .began)
        #expect(hitNode is TextViewNode)

        let pressedContext = UIGraphicsContext()
        tester.containerView.viewTree.renderGraph(renderContext: pressedContext)
        let pressedTransform = try #require(pressedContext.getDrawCommands().glassTransforms.first)

        #expect(pressedTransform.x.x == initialTransform.x.x)
        #expect(pressedTransform.y.y == initialTransform.y.y)
    }
}

private extension [UIGraphicsContext.DrawCommand] {
    var containsGlassDraw: Bool {
        firstIndexOfGlassDraw != nil
    }

    var containsTextDraw: Bool {
        firstIndexOfTextDraw != nil
    }

    var firstIndexOfGlassDraw: Int? {
        firstIndex {
            if case .drawGlassRect = $0 {
                return true
            }
            return false
        }
    }

    var firstIndexOfTextDraw: Int? {
        firstIndex {
            if case .drawText = $0 {
                return true
            }
            if case .drawGlyph = $0 {
                return true
            }
            return false
        }
    }

    var glassTransforms: [Transform3D] {
        compactMap { command in
            if case let .drawGlassRect(transform, _, _, _) = command {
                return transform
            }
            return nil
        }
    }

    var glassConfigurations: [Glass] {
        compactMap { command in
            if case let .drawGlassRect(_, _, configuration, _) = command {
                return configuration
            }
            return nil
        }
    }
}
