#if os(macOS)
import Testing
@testable import AdaPlatform

@Suite
@MainActor
struct MacApplicationFramePumpTests {
    @Test
    func eventsAreProcessedBeforeFrameUpdate() async {
        var order: [String] = []

        await MacApplicationFramePump.run(
            processEvents: {
                order.append("events")
            },
            update: {
                order.append("update")
            }
        )

        #expect(order == ["events", "update"])
    }
}
#endif
