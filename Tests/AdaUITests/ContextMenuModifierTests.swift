import AdaInput
import AdaUtils
import Math
import Testing

@_spi(Internal) @testable import AdaUI
@testable import AdaPlatform

@MainActor
@Suite(.serialized)
struct ContextMenuModifierTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func contextMenuPresentsOnRightClick() {
        var captured: ContextMenuPresentation?
        var didDelete = false

        ContextMenuPresentationCenter.present = { presentation in
            captured = presentation
        }

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        didDelete = true
                    }
                    Button("Rename") {}
                }
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), button: .right, phase: .began)

        #expect(captured?.location == Point(50, 50))
        #expect(captured?.items.map(\.title) == ["Delete", "Rename"])
        #expect(captured?.items.first?.role == .destructive)

        captured?.items.first?.action?()
        #expect(didDelete)

        ContextMenuPresentationCenter.present = nil
    }

    @Test
    func contextMenuPresentsSubmenus() {
        var captured: ContextMenuPresentation?
        var didOpenRecent = false

        ContextMenuPresentationCenter.present = { presentation in
            captured = presentation
        }

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .contextMenu {
                    ContextMenuSubmenu("Open") {
                        Button("Recent") {
                            didOpenRecent = true
                        }
                    }
                    Button("Close") {}
                }
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), button: .right, phase: .began)

        #expect(captured?.items.map(\.title) == ["Open", "Close"])
        #expect(captured?.items.first?.submenu.map(\.title) == ["Recent"])

        captured?.items.first?.submenu.first?.action?()
        #expect(didOpenRecent)

        ContextMenuPresentationCenter.present = nil
    }

    @Test
    func contextMenuPreservesSeparators() {
        var captured: ContextMenuPresentation?
        ContextMenuPresentationCenter.present = { presentation in
            captured = presentation
        }
        defer {
            ContextMenuPresentationCenter.present = nil
        }

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .contextMenu {
                    Button("Close") {}
                    Divider()
                    Button("Copy Path") {}
                }
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), button: .right, phase: .began)

        #expect(captured?.items.count == 3)
        #expect(captured?.items.map(\.isSeparator) == [false, true, false])
        #expect(captured?.items.filter { !$0.isSeparator }.map(\.title) == ["Close", "Copy Path"])
    }

    @Test
    func scrollViewEmptyAreaFallsThroughToBackgroundContextMenu() {
        var captured: ContextMenuPresentation?
        ContextMenuPresentationCenter.present = { presentation in
            captured = presentation
        }
        defer {
            ContextMenuPresentationCenter.present = nil
        }

        let tester = ViewTester {
            ZStack(anchor: .topLeading) {
                Color.clear
                    .frame(width: 200, height: 300)
                    .contextMenu {
                        Button("Background") {}
                    }

                ScrollView {
                    Color.red
                        .frame(width: 200, height: 40)
                        .contextMenu {
                            Button("Row") {}
                        }
                }
                .frame(width: 200, height: 300)
            }
        }
        .setSize(Size(width: 200, height: 300))
        .performLayout()

        tester.sendMouseEvent(at: Point(100, 200), button: .right, phase: .began)
        #expect(captured?.items.map(\.title) == ["Background"])

        captured = nil
        tester.sendMouseEvent(at: Point(100, 20), button: .right, phase: .began)
        #expect(captured?.items.map(\.title) == ["Row"])
    }

    @Test
    func primaryMouseHoldDoesNotPresentContextMenuOnDesktop() {
        var captured: ContextMenuPresentation?

        ContextMenuPresentationCenter.present = { presentation in
            captured = presentation
        }

        let tester = ViewTester {
            Color.red
                .frame(width: 100, height: 100)
                .contextMenu {
                    Button("Open") {}
                }
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(40, 40), phase: .began)
        tester.advanceFrame(deltaTime: 0.4)
        #expect(captured == nil)

        tester.advanceFrame(deltaTime: 0.4)
        #expect(captured == nil)
        tester.sendMouseEvent(at: Point(40, 40), phase: .ended)

        ContextMenuPresentationCenter.present = nil
    }

    @Test
    func primaryMouseHoldPreservesButtonActionOnDesktop() {
        var captured: ContextMenuPresentation?
        var didTapPrimaryAction = false

        ContextMenuPresentationCenter.present = { presentation in
            captured = presentation
        }

        let tester = ViewTester {
            Button("Primary") {
                didTapPrimaryAction = true
            }
            .frame(width: 100, height: 100)
            .contextMenu {
                Button("Open") {}
            }
        }
        .setSize(Size(width: 100, height: 100))
        .performLayout()

        tester.sendMouseEvent(at: Point(50, 50), phase: .began)
        tester.advanceFrame(deltaTime: 0.8)
        tester.sendMouseEvent(at: Point(50, 50), phase: .ended)

        #expect(captured == nil)
        #expect(didTapPrimaryAction)

        ContextMenuPresentationCenter.present = nil
    }

    @Test
    func contextMenuPreservesNestedPrimaryButtons() {
        var selected = 0
        var closed = 0

        let tester = ViewTester {
            HStack(spacing: 0) {
                Button("Select") {
                    selected += 1
                }
                .frame(width: 90, height: 32)

                Button("Close") {
                    closed += 1
                }
                .frame(width: 70, height: 32)
            }
            .contextMenu {
                Button("Close Tab") {}
            }
        }
        .setSize(Size(width: 160, height: 32))
        .performLayout()

        tester.sendMouseEvent(at: Point(45, 16), phase: .began)
        tester.sendMouseEvent(at: Point(45, 16), phase: .ended)
        tester.sendMouseEvent(at: Point(125, 16), phase: .began)
        tester.sendMouseEvent(at: Point(125, 16), phase: .ended)

        #expect(selected == 1)
        #expect(closed == 1)
    }

    @Test
    func activeWindowDeactivationRequestsContextMenuDismissal() {
        let window = UIWindow(frame: Rect(x: 0, y: 0, width: 200, height: 120))
        var deactivatedWindow: UIWindow?
        ContextMenuPresentationCenter.dismissForDeactivation = { sourceWindow in
            deactivatedWindow = sourceWindow
        }
        defer {
            ContextMenuPresentationCenter.dismissForDeactivation = nil
        }

        UIWindowManager.shared.setActiveWindow(window)
        #expect(window.isActive)

        UIWindowManager.shared.resignActiveWindow(window)

        #expect(deactivatedWindow === window)
        #expect(!window.isActive)
        #expect(UIWindowManager.shared.activeWindow == nil)
    }
}
