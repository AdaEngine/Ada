import AdaInput
import AdaUtils
@testable import AdaPlatform
@testable import AdaUI
import Math
import Testing

@MainActor
struct ScrollTextTouchTests {
    init() async throws { try Application.prepareForTest() }

    @Test
    func draggingStaticTextScrollsTheTranscript() throws {
        let tester = ViewTester {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Drag this message")
                        .frame(width: 180, height: 60)
                    Color.clear.frame(width: 180, height: 400)
                }
            }
            .accessibilityIdentifier("scroll")
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()
        let point = Point(50, 30)
        let contact = TouchEvent(window: .empty, location: point, phase: .began, time: 0)
        let scroll = try #require(tester.hitTest(point, event: contact) as? ScrollViewNode)
        tester.containerView.onTouchesEvent([contact])
        tester.containerView.onTouchesEvent([
            TouchEvent(window: .empty, location: Point(50, 10), phase: .moved, time: 0.02, contactID: contact.contactID)
        ])
        #expect(scroll.contentOffset.y == 20)
        tester.containerView.onTouchesEvent([
            TouchEvent(window: .empty, location: Point(50, 10), phase: .ended, time: 0.04, contactID: contact.contactID)
        ])
    }

    @Test
    func textButtonsKeepTheirTapTargetInsideScrollViews() throws {
        var taps = 0
        let tester = ViewTester {
            ScrollView {
                Button(action: { taps += 1 }) {
                    Text("Open").frame(width: 180, height: 60)
                }
            }
        }
        .setSize(Size(width: 200, height: 100))
        .performLayout()
        let point = Point(50, 30)
        let contact = TouchEvent(window: .empty, location: point, phase: .began, time: 0)
        #expect(!(tester.hitTest(point, event: contact) is ScrollViewNode))
        tester.containerView.onTouchesEvent([contact])
        tester.containerView.onTouchesEvent([
            TouchEvent(window: .empty, location: point, phase: .ended, time: 0.02, contactID: contact.contactID)
        ])
        #expect(taps == 1)
    }
}
