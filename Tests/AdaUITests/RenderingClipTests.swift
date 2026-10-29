//
//  RenderingClipTests.swift
//  AdaEngineTests
//
//  Created by Codex on 18.02.2026.
//

@testable import AdaPlatform
@_spi(Internal) import AdaRender
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
struct RenderingClipTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test(arguments: [false, true], [Float(1), 2])
    func nestedScrollViewportClipsFollowAncestorScrolling(horizontalOuter: Bool, scale: Float) throws {
        let tester = ViewTester {
            ScrollView(horizontalOuter ? .horizontal : .vertical) {
                ScrollView(horizontalOuter ? .vertical : .horizontal) {
                    Color.red.frame(width: 500, height: 400)
                }
                .accessibilityIdentifier("inner")
                .frame(width: 300, height: 260)
                .padding(12)
            }
            .accessibilityIdentifier("outer")
            .padding(20)
            .environment(\.scaleFactor, scale)
        }
        .setSize(Size(width: 240, height: 180))
        .performLayout()
        let outer = try #require(tester.findNodeByAccessibilityIdentifier("outer") as? ScrollViewNode)
        let inner = try #require(tester.findNodeByAccessibilityIdentifier("inner") as? ScrollViewNode)
        #expect(outer.scrollToVisibleRect(Rect(x: 210, y: 150, width: 20, height: 20), in: outer))
        #expect(inner.scrollToVisibleRect(Rect(x: 400, y: 350, width: 20, height: 20), in: inner))
        #expect(horizontalOuter ? outer.contentOffset.x > 0 : outer.contentOffset.y > 0)
        #expect(horizontalOuter ? inner.contentOffset.y > 0 : inner.contentOffset.x > 0)

        let layoutFrame = inner.absoluteFrame()
        let origin = layoutFrame.origin - outer.contentOffset
        let expected = Rect(
            x: max(0, origin.x) * scale,
            y: max(0, origin.y) * scale,
            width: max(0, origin.x + layoutFrame.width - max(0, origin.x)) * scale,
            height: max(0, origin.y + layoutFrame.height - max(0, origin.y)) * scale
        )
        let outerFrame = outer.absoluteFrame()
        let expectedOuter = Rect(
            origin: outerFrame.origin * scale,
            size: Size(width: outerFrame.width * scale, height: outerFrame.height * scale)
        )
        let root = tester.containerView.viewTree.rootNode
        for mode in [UIDebugOverlayMode.off, .layoutBounds, .focusedNode, .redraw] {
            let context = UIGraphicsContext()
            switch mode {
            case .off:
                root.draw(with: context)
            case .layoutBounds:
                root.drawInspectionLayoutBounds(with: context)
            case .focusedNode:
                root.drawInspectionSelectionBounds(with: context, mode: mode, focusedNode: inner, hitTestNode: nil)
            case .redraw:
                root.drawInspectionRedrawFlashes(with: context, baselineRevision: 0)
            case .hitTestTarget:
                break
            }
            let clips = context.getDrawCommands().compactMap { command -> Rect? in
                if case let .pushClipRect(rect) = command { return rect }
                return nil
            }
            #expect(clips.count == 2)
            #expect(clips.first == expectedOuter)
            #expect(clips.last == expected)
        }
    }

    @Test(arguments: [Float(1), 0.75, 0.5])
    func displayPixelClipsMatchScaledRenderViewport(_ renderScale: Float) throws {
        var context = UIGraphicsContext()
        context.environment.scaleFactor = 2
        context.pushClipRect(Rect(x: 100, y: 200, width: 240, height: 40))
        let command = try #require(context.getDrawCommands().first)
        guard case let .pushClipRect(clip) = command else {
            Issue.record("Expected a clip recorded by the graphics context")
            return
        }

        var camera = Camera()
        camera.computedData.targetScaleFactor = 2
        camera.logicalViewport.rect = Rect(x: 0, y: 0, width: 1194, height: 834)
        camera.viewport.rect = Rect(x: 12, y: 24, width: 2388 * renderScale, height: 1668 * renderScale)
        let decision = UIDrawPass().resolveScissorDecision(
            clipRect: clip,
            renderBounds: Rect(x: 0, y: 0, width: 2388, height: 1668),
            viewportOrigin: camera.viewport.rect.origin,
            clipScale: UIDrawPass.clipScale(for: camera)
        )
        #expect(decision == .apply(Rect(
            x: 200 * renderScale + 12,
            y: 400 * renderScale + 24,
            width: 480 * renderScale,
            height: 80 * renderScale
        )))
    }

    /// Verifies clipping rect keeps correct visible width when origin is negative.
    ///
    /// Example:
    /// - Input clip: `x = -50, width = 100`
    /// - Visible part in non-negative space must be `x = 0, width = 50`
    ///
    /// Regression protected:
    /// - origin is clamped to zero but width is left untouched (`100`),
    ///   which incorrectly expands clipped drawing region.
    @Test
    func graphicsContext_clipRect_intersectsWithNonNegativePlane() {
        var context = UIGraphicsContext()
        context.pushClipRect(Rect(x: -50, y: 0, width: 100, height: 100))

        guard let firstCommand = context.getDrawCommands().first else {
            Issue.record("Expected pushClipRect command.")
            return
        }

        guard case let .pushClipRect(clipped) = firstCommand else {
            Issue.record("First command is not pushClipRect.")
            return
        }

        #expect(clipped == Rect(x: 0, y: 0, width: 50, height: 100))
    }

    /// Verifies clipping rect that is fully outside non-negative plane becomes zero-sized.
    ///
    /// Regression protected:
    /// - negative-origin clip accidentally turns into a positive non-empty clip.
    @Test
    func graphicsContext_clipRect_outsideNonNegativePlane_becomesEmpty() {
        var context = UIGraphicsContext()
        context.pushClipRect(Rect(x: -20, y: -10, width: 10, height: 5))

        guard let firstCommand = context.getDrawCommands().first else {
            Issue.record("Expected pushClipRect command.")
            return
        }

        guard case let .pushClipRect(clipped) = firstCommand else {
            Issue.record("First command is not pushClipRect.")
            return
        }

        #expect(clipped == Rect(x: 0, y: 0, width: 0, height: 0))
    }

    /// Verifies draw pass skips rendering when clip rect does not intersect render target.
    ///
    /// Regression protected:
    /// - scissor fallback to full render bounds, which leaks draw outside clip.
    @Test
    func uiDrawPass_scissorDecision_skipsDrawForOutsideClip() {
        let pass = UIDrawPass()
        let decision = pass.resolveScissorDecision(
            clipRect: Rect(x: 150, y: 20, width: 40, height: 40),
            renderBounds: Rect(x: 0, y: 0, width: 100, height: 100),
            viewportOrigin: .zero
        )

        #expect(decision == .skipDraw)
    }

    /// Verifies zero-area clip is treated as fully clipped and skipped.
    @Test
    func uiDrawPass_scissorDecision_skipsDrawForZeroAreaClip() {
        let pass = UIDrawPass()
        let decision = pass.resolveScissorDecision(
            clipRect: Rect(x: 10, y: 10, width: 0, height: 20),
            renderBounds: Rect(x: 0, y: 0, width: 100, height: 100),
            viewportOrigin: .zero
        )

        #expect(decision == .skipDraw)
    }

    /// Verifies partial clip intersection is converted into bounded scissor rect.
    @Test
    func uiDrawPass_scissorDecision_clampsToRenderBounds() {
        let pass = UIDrawPass()
        let decision = pass.resolveScissorDecision(
            clipRect: Rect(x: -20, y: 10, width: 60, height: 40),
            renderBounds: Rect(x: 0, y: 0, width: 100, height: 100),
            viewportOrigin: .zero
        )

        #expect(decision == .apply(Rect(x: 0, y: 10, width: 40, height: 40)))
    }
}
