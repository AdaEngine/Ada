//
//  GestureTests.swift
//  AdaEngineTests
//
//  Created by Vladislav Prusakov on 25.03.2025.
//

import Testing
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import AdaUtils
import Math

@MainActor
struct GestureTests {

    init() async throws {
        try Application.prepareForTest()
    }

    // MARK: - TapGesture

    @Test
    func tapGesture_firesOnMouseClick() {
        var tapped = false

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .onTap { tapped = true }
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), phase: .began)
        tester.sendMouseEvent(at: Point(50, 50), phase: .ended)

        #expect(tapped)
    }

    @Test
    func middleClickModifier_firesOnlyForMiddleMouseButton() {
        var clickCount = 0

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .onMiddleClick { clickCount += 1 }
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), phase: .began)
        tester.sendMouseEvent(at: Point(50, 50), phase: .ended)
        #expect(clickCount == 0)

        tester.sendMouseEvent(at: Point(50, 50), button: .middle, phase: .began)
        tester.sendMouseEvent(at: Point(50, 50), button: .middle, phase: .ended)
        #expect(clickCount == 1)
    }

    @Test
    func middleClickModifier_preservesNestedButtonLeftClick() {
        var buttonClickCount = 0
        var middleClickCount = 0

        let tester = ViewTester {
            Button("Open") {
                buttonClickCount += 1
            }
            .frame(width: 100, height: 40)
            .onMiddleClick {
                middleClickCount += 1
            }
        }
        .setSize(Size(width: 100, height: 40))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 20), phase: .began)
        tester.sendMouseEvent(at: Point(50, 20), phase: .ended)

        #expect(buttonClickCount == 1)
        #expect(middleClickCount == 0)
    }

    @Test
    func tapGesture_doesNotFireWhenClickOutsideBounds() {
        var tapped = false

        let tester = ViewTester {
            Color.red
                .frame(width: 50, height: 50)
                .onTap { tapped = true }
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.sendMouseEvent(at: Point(180, 180), phase: .began)
        tester.sendMouseEvent(at: Point(180, 180), phase: .ended)

        #expect(!tapped)
    }

    @Test
    func tapGesture_withCount_firesAfterRequiredTaps() {
        var tapped = false

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { tapped = true }
                )
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), phase: .began)
        tester.sendMouseEvent(at: Point(50, 50), phase: .ended)
        tester.sendMouseEvent(at: Point(50, 50), phase: .began)
        tester.sendMouseEvent(at: Point(50, 50), phase: .ended)

        #expect(tapped)
    }

    @Test
    func tapGesture_singleCount_doesNotFireOnDoubleRequirement() {
        var tapped = false

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { tapped = true }
                )
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), phase: .began)
        tester.sendMouseEvent(at: Point(50, 50), phase: .ended)

        #expect(!tapped)
    }

    // MARK: - DragGesture

    @Test
    func dragGesture_onEnded_firesWithCorrectTranslation() {
        var endedValue: DragGesture.Value?

        let tester = ViewTester {
            Color.red
                .frame(width: 200, height: 200)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { endedValue = $0 }
                )
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 100), phase: .began)
        tester.sendMouseEvent(at: Point(150, 120), button: .left, phase: .changed)
        tester.sendMouseEvent(at: Point(150, 120), phase: .ended)

        #expect(endedValue != nil)
        #expect(endedValue?.translation.width == 50)
        #expect(endedValue?.translation.height == 20)
    }

    @Test
    func dragGesture_onChanged_firesWhileDragging() {
        var changedValues: [DragGesture.Value] = []

        let tester = ViewTester {
            Color.red
                .frame(width: 200, height: 200)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { changedValues.append($0) }
                )
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 100), phase: .began)
        tester.sendMouseEvent(at: Point(110, 100), button: .left, phase: .changed)
        tester.sendMouseEvent(at: Point(120, 100), button: .left, phase: .changed)
        tester.sendMouseEvent(at: Point(120, 100), phase: .ended)

        #expect(changedValues.count == 2)
        #expect(changedValues.last?.translation.width == 20)
    }

    @Test
    func dragGesture_onChangedAndEnded_bothFire() {
        var changedCount = 0
        var ended = false

        let tester = ViewTester {
            Color.red
                .frame(width: 200, height: 200)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in changedCount += 1 }
                        .onEnded { _ in ended = true }
                )
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 100), phase: .began)
        tester.sendMouseEvent(at: Point(130, 100), button: .left, phase: .changed)
        tester.sendMouseEvent(at: Point(130, 100), phase: .ended)

        #expect(changedCount > 0)
        #expect(ended)
    }

    @Test
    func dragGesture_recoversWhenMouseButtonReleaseWasMissed() {
        var changedCount = 0
        var endedCount = 0

        let tester = ViewTester {
            Color.red
                .frame(width: 200, height: 200)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in changedCount += 1 }
                        .onEnded { _ in endedCount += 1 }
                )
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 100), phase: .began)
        tester.sendMouseEvent(at: Point(130, 100), button: .left, phase: .changed)
        tester.sendMouseEvent(at: Point(140, 100), button: .none, phase: .changed)
        tester.sendMouseEvent(at: Point(150, 100), button: .none, phase: .changed)

        #expect(changedCount == 1)
        #expect(endedCount == 1)
    }

    // MARK: - LongPressGesture

    @Test
    func longPressGesture_firesAfterMinimumDuration() {
        var fired = false

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .gesture(
                    LongPressGesture(minimumDuration: 1.0)
                        .onEnded { fired = true }
                )
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), phase: .began)

        let rootNode = tester.containerView.viewTree.rootNode
        rootNode.update(0.5)
        #expect(!fired)

        rootNode.update(0.6)
        #expect(fired)
    }

    @Test
    func longPressGesture_doesNotFireBeforeMinimumDuration() {
        var fired = false

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .gesture(
                    LongPressGesture(minimumDuration: 1.0)
                        .onEnded { fired = true }
                )
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), phase: .began)
        tester.containerView.viewTree.rootNode.update(0.5)

        #expect(!fired)
    }

    // MARK: - onHover

    @Test
    func onHover_firesWhenMouseEnters() {
        var hovering = false

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .onHover { hovering = $0 }
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), button: .none, phase: .changed)

        #expect(hovering == true)
    }

    @Test
    func onHover_firesWhenMouseLeaves() {
        var hoverEvents: [Bool] = []

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .onHover { hoverEvents.append($0) }
        }
        .setSize(Size(width: 200, height: 200))
        .performLayout()

        // The hover view (100x100) is centered in the 200x200 container, occupying (50,50)-(150,150).
        // Point (100, 100) is the center of the hover view; Point (20, 20) is clearly outside.
        tester.sendMouseEvent(at: Point(100, 100), button: .none, phase: .changed)
        tester.sendMouseEvent(at: Point(20, 20), button: .none, phase: .changed)

        #expect(hoverEvents.contains(true))
        #expect(hoverEvents.contains(false))
    }

    @Test
    func cursorShape_setsWindowCursorWhilePointerIsInside() {
        let container = UIContainerView(
            rootView: HStack(spacing: 0) {
                Color.red
                    .frame(width: 100, height: 100)
                    .cursorShape(.resizeLeftRight)

                Color.blue
                    .frame(width: 100, height: 100)
            }
        )
        container.frame = Rect(x: 0, y: 0, width: 200, height: 100)

        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 200, height: 100))
        window.addSubview(container)
        window.layoutSubviews()

        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .none,
                mousePosition: Point(50, 50),
                phase: .changed,
                modifierKeys: [],
                time: 0
            )
        )
        #expect(window.windowManager.getCursorShape() == .resizeLeftRight)

    }

    @Test
    func cursorShape_preservesDestinationCursorWhenMovingBetweenCursorRegions() {
        let container = UIContainerView(
            rootView: HStack(spacing: 0) {
                Color.red
                    .frame(width: 100, height: 100)
                    .cursorShape(.resizeLeftRight)

                Color.blue
                    .frame(width: 100, height: 100)
                    .cursorShape(.iBeam)
            }
        )
        container.frame = Rect(x: 0, y: 0, width: 200, height: 100)

        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 200, height: 100))
        window.addSubview(container)
        window.layoutSubviews()

        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .none,
                mousePosition: Point(50, 50),
                phase: .changed,
                modifierKeys: [],
                time: 0
            )
        )
        window.sendEvent(
            MouseEvent(
                window: window.id,
                button: .none,
                mousePosition: Point(150, 50),
                phase: .changed,
                modifierKeys: [],
                time: 0
            )
        )

        #expect(window.windowManager.getCursorShape() == .iBeam)
    }

    // MARK: - Gesture Combining

    @Test
    func simultaneousGesture_compilesAndInstantiates() {
        var tapped = false
        var changed = false

        let gesture = TapGesture()
            .onEnded { tapped = true }
            .simultaneously(with:
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in changed = true }
            )

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .gesture(gesture)
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), phase: .began)
        tester.sendMouseEvent(at: Point(60, 50), button: .left, phase: .changed)
        tester.sendMouseEvent(at: Point(60, 50), phase: .ended)

        #expect(tapped)
        #expect(changed)
    }
}
