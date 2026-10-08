@testable import AdaUI
import AdaApp
import AdaECS
import AdaInput
import AdaRender
import AdaUtils
import Math
import Testing

@MainActor @Suite(.serialized)
struct VirtualJoystickTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Joystick tests")))
        }
    }

    @Test func hiddenThumbAppearsOnDragAndResetsOnCancel() {
        var x: Float = 0, y: Float = 0
        let host = JoystickHost()
        host.style = .invisibleUntilDragged
        host.frame = Rect(x: 0, y: 0, width: 96, height: 96)
        host.x = Binding(get: { x }, set: { x = $0 })
        host.y = Binding(get: { y }, set: { y = $0 })
        func move(_ point: Point, _ phase: MouseEvent.Phase) {
            host.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
        }
        #expect(host.thumbOpacity == 0)
        move(Point(48, 48), .began)
        #expect(host.thumbOpacity == 0)
        move(Point(49, 48), .changed)
        #expect(x == 0 && host.thumbOpacity == 0)
        move(Point(75, 48), .changed)
        #expect(x == 1 && host.thumbOpacity == 1)
        move(Point(48, 48), .changed)
        #expect(host.thumbOpacity == 1) // Remains visible until the contact ends.
        move(Point(48, 48), .cancelled)
        #expect(x == 0 && y == 0 && host.thumbOpacity == 0)
    }

    @Test func customDimensionsControlTravelAndReleaseOnRemoval() {
        var x: Float = 0
        let host = JoystickHost()
        host.style = VirtualJoystickStyle(diameter: 160, thumbDiameter: 40, movementRadius: 50, deadZone: 0.2)
        host.frame = Rect(x: 0, y: 0, width: 160, height: 160)
        host.x = Binding(get: { x }, set: { x = $0 })
        host.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(105, 80), phase: .began, modifierKeys: [], time: 0))
        #expect(x == 0.5)
        host.viewWillMove(to: Optional<UIView>.none)
        #expect(x == 0 && !host.isDragging)
    }

    @Test func invalidStyleIsBounded() {
        let style = VirtualJoystickStyle(diameter: .nan, thumbDiameter: 999, movementRadius: -.infinity, deadZone: -2,
                                         ringWidth: -1, idleOpacity: 3, activeOpacity: .nan, idleThumbOpacity: -1).resolved
        #expect(style.diameter == 96 && style.thumbDiameter == 96)
        #expect(style.movementRadius == 0 && style.deadZone == 0 && style.ringWidth == 0)
        #expect(style.idleOpacity == 1 && style.activeOpacity == 1 && style.idleThumbOpacity == 0)
    }
    @Test func virtualStickAndJumpHaveIndependentContacts() {
        var x: Float = 0, y: Float = 0
        var jumps = 0
        let container = UIContainerView(rootView: HStack(spacing: 20) {
            VirtualJoystick(x: Binding(get: { x }, set: { x = $0 }), y: Binding(get: { y }, set: { y = $0 }))
            Button("Jump") { jumps += 1 }.frame(width: 96, height: 96)
        })
        container.frame = Rect(x: 0, y: 0, width: 212, height: 96)
        container.layoutSubviews()
        let window = RID(), stick = RID(), jump = RID()
        func touch(_ id: RID, _ x: Float, _ phase: TouchEvent.Phase) {
            container.onTouchesEvent([TouchEvent(window: window, location: Point(x, 48), phase: phase, time: 0, contactID: id)])
        }
        touch(stick, 72, .began)
        #expect(x > 0.5)
        touch(jump, 164, .began); touch(jump, 164, .ended)
        #expect(jumps == 1)
        #expect(x > 0.5)
        touch(stick, 80, .moved)
        #expect(x == 1)
        touch(stick, 80, .cancelled)
        #expect(x == 0 && y == 0)
    }


    @Test func uiFileParametersDriveActualInputGeometry() throws {
        let context = UIBindingContext(values: ["x": .number(0), "y": .number(0)])
        let document = UISceneDocument(root: .init(type: "VirtualJoystick", arguments: [
            "x": .init(binding: "x"), "y": .init(binding: "y"),
            "diameter": .init(value: .number(160)), "movementRadius": .init(value: .number(50)),
            "thumbDiameter": .init(value: .number(40)), "idleThumbOpacity": .init(value: .number(0)),
            "baseColor": .init(value: .string("#11223380"))
        ]))
        let session = try UISceneInstance(document: document, context: context)
        let container = UIContainerView(rootView: UISceneView(session: session))
        container.frame = Rect(x: 0, y: 0, width: 160, height: 160)
        container.layoutSubviews()
        let window = RID(), contact = RID()
        container.onTouchesEvent([TouchEvent(window: window, location: Point(105, 80), phase: .began, time: 0, contactID: contact)])
        #expect(abs((context.value("x")?.number ?? 0) - 0.5) < 0.001)
        container.onTouchesEvent([TouchEvent(window: window, location: Point(105, 80), phase: .ended, time: 0, contactID: contact)])
        #expect(context.value("x") == .number(0))
    }

}
