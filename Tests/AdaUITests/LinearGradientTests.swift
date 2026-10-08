//
//  LinearGradientTests.swift
//  AdaEngine
//
//  Created by Codex on 17.04.2026.
//

import Testing
import AdaCorePipelines
@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math

@MainActor
struct LinearGradientTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func colorsInitializer_buildsEvenlyDistributedStops() {
        let gradient = LinearGradient(
            colors: [.red, .green, .blue],
            startPoint: .leading,
            endPoint: .trailing
        )

        #expect(gradient.gradient.stops.count == 3)
        #expect(gradient.gradient.stops[0] == Gradient.Stop(color: .red, location: 0))
        #expect(gradient.gradient.stops[1] == Gradient.Stop(color: .green, location: 0.5))
        #expect(gradient.gradient.stops[2] == Gradient.Stop(color: .blue, location: 1))
    }

    @Test
    func stopsInitializer_sortsClampsAndLimitsStops() {
        let gradient = LinearGradient(
            stops: [
                .init(color: .green, location: 1.4),
                .init(color: .red, location: -1),
                .init(color: .blue, location: 0.4)
            ] + (0..<20).map {
                .init(color: .white, location: Float($0) / 19)
            },
            startPoint: .top,
            endPoint: .bottom
        )

        #expect(gradient.gradient.stops.count == Gradient.maximumStops)
        #expect(gradient.gradient.stops.first?.location == 0)
        #expect(gradient.gradient.stops.last?.location == 1)
        #expect(gradient.gradient.stops == gradient.gradient.stops.sorted { $0.location < $1.location })
    }

    @Test
    func emptyAndSingleColorInitializers_fallbackPredictably() {
        let empty = LinearGradient(
            colors: [],
            startPoint: .top,
            endPoint: .bottom
        )
        let single = LinearGradient(
            colors: [.mint],
            startPoint: .top,
            endPoint: .bottom
        )

        #expect(empty.gradient.stops == [
            Gradient.Stop(color: .clear, location: 0),
            Gradient.Stop(color: .clear, location: 1)
        ])
        #expect(single.gradient.stops == [
            Gradient.Stop(color: .mint, location: 0),
            Gradient.Stop(color: .mint, location: 1)
        ])
    }

    @Test
    func sizeThatFits_matchesColorBehaviour() {
        let tester = ViewTester(rootView: LinearGradient(
            colors: [.red, .blue],
            startPoint: .top,
            endPoint: .bottom
        ))
        let size = tester.containerView.viewTree.rootNode.sizeThatFits(
            ProposedViewSize(width: 320, height: 180)
        )

        #expect(size == Size(width: 320, height: 180))
    }

    @Test
    func linearGradient_drawsExpectedCommand() {
        let tester = ViewTester(rootView: LinearGradient(
            colors: [.red, .blue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
        let context = UIGraphicsContext()

        tester.containerView.viewTree.rootNode.draw(with: context)

        let commands = context.getDrawCommands()
        guard case let .drawLinearGradient(transform, startPoint, endPoint, stops)? = commands.first else {
            Issue.record("Expected a drawLinearGradient command.")
            return
        }

        #expect(transform == Rect(x: 0, y: 0, width: 800, height: 600).toTransform3D)
        #expect(startPoint == UnitPoint.topLeading.asVector2)
        #expect(endPoint == UnitPoint.bottomTrailing.asVector2)
        #expect(stops.count == 2)
    }

    @Test
    func background_withLinearGradient_keepsContentSizeAndDrawsBehindContent() {
        let tester = ViewTester {
            Text("Gradient")
                .accessibilityIdentifier("content")
                .background {
                    LinearGradient(
                        colors: [.red, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .accessibilityIdentifier("gradient")
                }
        }
        .performLayout()

        let contentNode = tester.findNodeByAccessibilityIdentifier("content")
        let gradientNode = tester.findNodeByAccessibilityIdentifier("gradient")

        #expect(contentNode != nil)
        #expect(gradientNode != nil)
        #expect(contentNode?.frame.size == gradientNode?.frame.size)

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)
        let commands = context.getDrawCommands()

        #expect(commands.count >= 2)
        guard commands.contains(where: { command in
            if case .drawLinearGradient = command {
                return true
            }
            return false
        }) else {
            Issue.record("Expected gradient draw command to be emitted before content.")
            return
        }
    }

    @Test
    func linearGradientUniform_serializesAxisAndDegenerateCase() {
        let diagonal = LinearGradientUniform(
            startPoint: UnitPoint.topLeading.asVector2,
            endPoint: UnitPoint.bottomTrailing.asVector2,
            stops: [
                .init(color: .red, location: 0),
                .init(color: .blue, location: 1)
            ]
        )
        let degenerate = LinearGradientUniform(
            startPoint: UnitPoint.center.asVector2,
            endPoint: UnitPoint.center.asVector2,
            stops: [
                .init(color: .green, location: 0.25)
            ]
        )

        #expect(diagonal.startPoint == UnitPoint.topLeading.asVector2)
        #expect(diagonal.endPoint == UnitPoint.bottomTrailing.asVector2)
        #expect(diagonal.stopCount == 2)
        #expect(degenerate.startPoint == degenerate.endPoint)
        #expect(degenerate.stopCount == 2)
        #expect(degenerate.stopColor0 == Color.green.asVector)
        #expect(degenerate.stopColor1 == Color.green.asVector)
    }

    @Test
    func linearGradientUniform_matchesShaderUniformLayout() {
        #expect(MemoryLayout<LinearGradientUniform>.stride == 352)
        #expect(MemoryLayout<LinearGradientUniform>.offset(of: \.stopColor0) == 32)
        #expect(MemoryLayout<LinearGradientUniform>.offset(of: \.stopLocations3) == 336)
    }

    @Test
    func linearGradientTessellation_flipsTextureCoordinatesForUIKitStyleY() {
        let vertices = UITessellator().tessellateLinearGradient(transform: .identity)

        #expect(vertices.map(\.textureCoordinate) == [
            Vector2(0, 1),
            Vector2(1, 1),
            Vector2(1, 0),
            Vector2(0, 0),
        ])
    }
}
