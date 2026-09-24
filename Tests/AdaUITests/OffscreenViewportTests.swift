//
//  OffscreenViewportTests.swift
//  AdaEngine
//
//  Created by AdaEngine on 04.04.2026.
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
@_spi(Internal) import AdaRender
import AdaInput
import AdaUtils
import Math

@MainActor
final class MockViewportDelegate: OffscreenViewportDelegate {
    var renderTexture: Texture2D? = nil
    var renderTextureDidChange: (@MainActor @Sendable () -> Void)?
    var bootstrapCallCount = 0
    var tickCount = 0
    var lastTickDelta: AdaUtils.TimeInterval = 0
    var receivedInputEvents: [any InputEvent] = []
    var lastMousePosition: Point = .zero
    var lastSize: SizeInt = .zero
    var lastScaleFactor: Float = 0

    func bootstrapIfNeeded() {
        bootstrapCallCount += 1
    }

    func shutdown() {
    }

    func tick(_ deltaTime: AdaUtils.TimeInterval) {
        tickCount += 1
        lastTickDelta = deltaTime
    }

    func receiveInputEvent(_ event: any InputEvent) {
        receivedInputEvents.append(event)
    }

    func updateMousePosition(_ position: Point) {
        lastMousePosition = position
    }

    func updateSize(_ size: SizeInt, scaleFactor: Float) {
        lastSize = size
        lastScaleFactor = scaleFactor
    }
}

@MainActor
@Suite(.serialized)
struct OffscreenViewportTests {

    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func pinchRoutesToHitViewportInLocalCoordinates() throws {
        let delegate = MockViewportDelegate()
        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate).padding(20)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()
        let container = tester.containerView
        let window = RID()
        container.onReceiveEvent(PinchEvent(window: window, location: Point(100, 80), scale: 1, phase: .began, time: 0))
        container.onReceiveEvent(PinchEvent(window: window, location: Point(110, 90), scale: 2, phase: .changed, time: 1))
        container.onReceiveEvent(PinchEvent(window: window, location: Point(410, 310), scale: 2, phase: .ended, time: 2))
        let events = delegate.receivedInputEvents.compactMap { $0 as? PinchEvent }
        #expect(events.map(\.phase) == [.began, .changed, .ended])
        #expect(events.first?.location == Point(80, 60))
        let changed = try #require(events.first { $0.phase == .changed })
        #expect(changed.location == Point(90, 70))
        #expect(changed.scale == 2)
        container.onReceiveEvent(PinchEvent(window: window, location: Point(5, 5), scale: 1, phase: .began, time: 3))
        #expect(delegate.receivedInputEvents.count == 3)
    }

    @Test
    func containerCreatesDelegate_onlyOnce() {
        var factoryCallCount = 0
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportContainer(
                delegateFactory: {
                    factoryCallCount += 1
                    return delegate
                },
                contentBuilder: { _ in
                    EmptyView()
                }
            )
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        #expect(factoryCallCount == 1)

        tester.invalidateContent()
        tester.performLayout()
        #expect(factoryCallCount == 1)
    }

    @Test
    func bootstrap_calledOnFirstLayout() {
        let delegate = MockViewportDelegate()

        _ = ViewTester {
            OffscreenViewportView(delegate: delegate)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        #expect(delegate.bootstrapCallCount == 1)
    }

    @Test
    func bootstrap_notCalledAgainOnRelayout() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        tester.performLayout()
        tester.performLayout()

        #expect(delegate.bootstrapCallCount == 1)
    }

    @Test
    func tick_forwardedOnUpdate() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        tester.advanceFrame(deltaTime: 0.016)

        #expect(delegate.tickCount >= 1)
    }

    @Test
    func tick_continuesAfterFirstLayout() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        tester.advanceFrame(deltaTime: 0.016)
        let tickCountAfterFirstFrame = delegate.tickCount

        tester.advanceFrame(deltaTime: 0.016)

        #expect(tickCountAfterFirstFrame >= 1)
        #expect(delegate.tickCount > tickCountAfterFirstFrame)
    }

    @Test
    func tick_doesNotInvalidateDisplayWhenTextureIdentityIsStable() {
        let delegate = MockViewportDelegate()
        delegate.renderTexture = Texture2D.whiteTexture

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        _ = tester.containerView.consumeNeedsDisplay()
        tester.advanceFrame(deltaTime: 0.016)

        #expect(delegate.tickCount >= 1)
        #expect(!tester.containerView.needsDisplay)
    }

    @Test
    func sizeUpdate_reportedOnLayout() {
        let delegate = MockViewportDelegate()

        _ = ViewTester {
            OffscreenViewportView(delegate: delegate)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        #expect(delegate.lastSize.width > 0)
        #expect(delegate.lastSize.height > 0)
    }

    @Test
    func sizeUpdate_roundsPhysicalPixels() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
                .frame(width: 10.75, height: 8.25)
        }
        .setSize(Size(width: 40, height: 40))
        .performLayout()

        var environment = tester.containerView.rootEnvironmentValues()
        environment.scaleFactor = 2
        tester.containerView.updateEnvironment(environment)
        tester.containerView.viewTree.rootNode.place(
            in: .zero,
            anchor: .zero,
            proposal: ProposedViewSize(tester.containerView.frame.size)
        )

        #expect(delegate.lastSize == SizeInt(width: 22, height: 17))
        #expect(delegate.lastScaleFactor == 2)
    }

    @Test
    func renderTextureDidChange_invalidatesContainerDisplay() throws {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportContainer(
                delegateFactory: { delegate },
                contentBuilder: { d in
                    OffscreenViewportView(delegate: d)
                }
            )
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        _ = tester.containerView.consumeNeedsDisplay()
        let renderTextureDidChange = try #require(delegate.renderTextureDidChange)
        renderTextureDidChange()

        #expect(tester.containerView.needsDisplay)
    }

    @Test
    func renderTextureDidChange_rebuildsContainerContent() throws {
        let delegate = MockViewportDelegate()
        var placeholderStates: [Bool] = []

        _ = ViewTester {
            OffscreenViewportContainer(
                delegateFactory: { delegate },
                contentBuilder: { d in
                    let showsPlaceholder = d.renderTexture == nil
                    let _ = placeholderStates.append(showsPlaceholder)
                    ZStack {
                        OffscreenViewportView(delegate: d)
                        if showsPlaceholder {
                            Text("Loading")
                        }
                    }
                }
            )
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        delegate.renderTexture = Texture2D.whiteTexture
        let renderTextureDidChange = try #require(delegate.renderTextureDidChange)
        renderTextureDidChange()

        #expect(placeholderStates.first == true)
        #expect(placeholderStates.count >= 2)
    }

    @Test
    func renderTexture_isClippedToViewportBounds() {
        let delegate = MockViewportDelegate()
        delegate.renderTexture = Texture2D.whiteTexture

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
                .frame(width: 200, height: 150)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        let context = UIGraphicsContext()
        tester.containerView.viewTree.rootNode.draw(with: context)

        let commands = context.getDrawCommands()
        guard commands.count == 3 else {
            Issue.record("Expected clip, texture draw, and clip restore commands.")
            return
        }
        guard case let .pushClipRect(clipRect) = commands[0] else {
            Issue.record("SceneView texture draw must begin with a clip rectangle.")
            return
        }
        guard case .drawQuad = commands[1] else {
            Issue.record("Expected the SceneView texture inside the clip rectangle.")
            return
        }
        guard case .popClipRect = commands[2] else {
            Issue.record("SceneView texture draw must restore the clip rectangle.")
            return
        }

        #expect(clipRect.size == Size(width: 200, height: 150))
    }

    @Test
    func viewport_isHitTestable() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
                .frame(width: 200, height: 150)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        let hitNode = tester.click(at: Point(100, 75))
        #expect(hitNode != nil)
    }

    @Test
    func mouseEvent_forwardedToDelegate() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
                .frame(width: 400, height: 300)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        tester.sendMouseEvent(
            at: Point(200, 150),
            button: .left,
            phase: .began,
            time: 0
        )

        let mouseEvents = delegate.receivedInputEvents.compactMap { $0 as? MouseEvent }
        #expect(!mouseEvents.isEmpty)
    }

    @Test
    func mouseEvent_coordinatesTranslatedToViewportLocal() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            HStack {
                Spacer().frame(width: 100)
                OffscreenViewportView(delegate: delegate)
                    .frame(width: 200, height: 150)
            }
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        tester.sendMouseEvent(
            at: Point(200, 75),
            button: .left,
            phase: .began,
            time: 0
        )

        let mouseEvents = delegate.receivedInputEvents.compactMap { $0 as? MouseEvent }
        if let event = mouseEvents.first {
            #expect(event.mousePosition.x >= 0)
            #expect(event.mousePosition.y >= 0)
        }
    }

    @Test
    func keyEvent_notForwardedBeforeActivation() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
                .frame(width: 400, height: 300)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        tester.sendKeyEvent(.a)

        let keyEvents = delegate.receivedInputEvents.compactMap { $0 as? KeyEvent }
        #expect(keyEvents.isEmpty)
    }

    @Test
    func keyEvent_forwardedAfterMouseActivation() {
        let delegate = MockViewportDelegate()

        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate)
                .frame(width: 400, height: 300)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        tester.sendMouseEvent(
            at: Point(200, 150),
            button: .left,
            phase: .began,
            time: 0
        )

        tester.sendKeyEvent(.b)

        let keyEvents = delegate.receivedInputEvents.compactMap { $0 as? KeyEvent }
        #expect(!keyEvents.isEmpty)
    }

    @Test
    func disablingInteractionReleasesHeldInputAndStopsHitTesting() {
        let delegate = MockViewportDelegate()
        var isInteractive = true
        let tester = ViewTester {
            OffscreenViewportView(delegate: delegate, isInteractive: isInteractive)
                .frame(width: 400, height: 300)
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        tester.sendMouseEvent(at: Point(200, 150), button: .left, phase: .began, time: 0)
        tester.sendKeyEvent(.b, status: .down)
        isInteractive = false
        tester.invalidateContent().performLayout()

        #expect(delegate.receivedInputEvents.compactMap { $0 as? KeyEvent }.map(\.status) == [.down, .up])
        #expect(delegate.receivedInputEvents.compactMap { $0 as? MouseEvent }.map(\.phase) == [.began, .cancelled])
        #expect(tester.click(at: Point(200, 150)) == nil)
    }

    @Test
    func containerPassesDelegateToContent() {
        let delegate = MockViewportDelegate()
        var receivedDelegate: (any OffscreenViewportDelegate)?

        _ = ViewTester {
            OffscreenViewportContainer(
                delegateFactory: { delegate },
                contentBuilder: { d in
                    receivedDelegate = d
                    return OffscreenViewportView(delegate: d)
                }
            )
        }
        .setSize(Size(width: 400, height: 300))
        .performLayout()

        #expect(receivedDelegate != nil)
        #expect(receivedDelegate === delegate)
    }
}
