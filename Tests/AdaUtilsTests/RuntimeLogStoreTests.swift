import Logging
import Testing
@testable import AdaUtils

@Suite("Runtime log store")
struct RuntimeLogStoreTests {
    @Test("swift-log messages reach the runtime diagnostic store")
    func recordsLoggerMessages() {
        let store = RuntimeLogStore(capacity: 2)
        store.setEnabled(true)
        let logger = Logger(label: "client", factory: { RuntimeLogHandler(label: $0, store: store) })

        RuntimeLogStore.$currentSource.withValue("Client") {
            logger.info("Connected")
        }

        let batch = store.read()
        #expect(batch.entries.count == 1)
        #expect(batch.entries.first?.level == "info")
        #expect(batch.entries.first?.label == "client")
        #expect(batch.entries.first?.message == "Connected")
        #expect(batch.entries.first?.source == "Client")
    }

    @Test("bounded logs report overflow independently for each reader")
    func reportsOverflow() {
        let store = RuntimeLogStore(capacity: 2)
        store.setEnabled(true)
        for message in ["one", "two", "three"] {
            store.append(level: "info", label: "client", message: message)
        }
        let batch = store.read(after: 0)
        #expect(batch.entries.map(\.message) == ["two", "three"])
        #expect(batch.dropped == 1)
        #expect(store.read(after: batch.nextCursor).entries.isEmpty)
        #expect(store.read(after: 1).entries.count == 2)
    }
}
