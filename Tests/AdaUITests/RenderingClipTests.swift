//
//  RenderingClipTests.swift
//  AdaEngineTests
//
//  Created by Codex on 18.02.2026.
//

@testable import AdaPlatform
@_spi(Internal) import AdaRender
@testable import AdaUI
import Math
import Testing

@MainActor
struct RenderingClipTests {
    init() async throws {
        try Application.prepareForTest()
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
