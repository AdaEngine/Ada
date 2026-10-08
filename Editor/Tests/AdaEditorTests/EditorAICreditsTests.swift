@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Cloud AI credits", .serialized)
@MainActor
struct EditorAICreditsTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AICreditsUI")))
        }
    }

    private let owner = "11111111-1111-4111-8111-111111111111"
    private let catalog: EditorCloudValue = [
        "enabled": false, "availability": ["cloudServicesAvailable": false], "tariffVersion": "test",
        "microcreditsPerCredit": 1_000_000, "plans": [["id": "pro", "monthlyMicrocredits": 500_000_000]], "capabilities": [],
    ]

    private func wallet(available: Int64 = 424_999_999, spent: Int64 = 1, reserved: Int64 = 75_000_000) -> EditorCloudValue {
        ["accountID": .string(owner), "cycleStart": 1_700_000_000, "cycleEnd": 1_702_592_000,
         "allowance": 500_000_000, "spent": .integer(spent), "reserved": .integer(reserved),
         "available": .integer(available), "scale": 1_000_000, "suspended": false, "closed": false]
    }

    @Test("Microcredits remain exact, including sub-credit balances and negative ledger adjustments")
    func precision() {
        #expect(EditorAICreditAmount.text(500_000_000) == "500")
        #expect(EditorAICreditAmount.text(424_999_999) == "424.999999")
        #expect(EditorAICreditAmount.text(1) == "0.000001")
        #expect(EditorAICreditAmount.text(-75_000_000) == "−75")
        #expect(EditorAICreditAmount.text(.min) == "−9223372036854.775808")
    }

    @Test("Spendable balance comes from the wallet; disabled execution still shows the real allowance")
    func counterAndLayout() async throws {
        let model = EditorAICreditsModel()
        let client = EditorCloudAIClient(owner: owner) { path, _, _ in path == "/ai/catalog" ? catalog : wallet() }
        model.reset(signedIn: true)
        await model.refresh(client: client)
        #expect(model.counterText == "424.999999 credits")
        #expect(model.summary == "Hosted AI will open soon.")
        #expect(model.balance?.reserved == 75_000_000)
        let container = UIContainerView(rootView: EditorAICreditsDetails(model: model, refresh: {}, loadHistory: {}))
        container.frame = Rect(x: 0, y: 0, width: 340, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let amount = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Available"))
        let refresh = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Refresh"))
        #expect(amount.absoluteFrame.width > 0)
        #expect(amount.absoluteFrame.maxY <= refresh.absoluteFrame.minY)
    }

    @Test("A real zero differs from a missing endpoint or failed request")
    func zeroAndUnavailable() async {
        let model = EditorAICreditsModel()
        let client = EditorCloudAIClient(owner: owner) { path, _, _ in path == "/ai/catalog" ? catalog : wallet(available: 0, spent: 500_000_000, reserved: 0) }
        await model.refresh(client: client)
        #expect(model.counterText == "0 credits")
        for status in [404, 503, 401, 500] {
            let failing = EditorCloudAIClient(owner: owner) { _, _, _ in throw EditorCloudAccount.CloudError.http(status, "Unavailable") }
            await model.refresh(client: failing, force: true)
            #expect(model.balance == nil)
            #expect(model.counterText == "Credits —")
            #expect(model.phase == ([404, 503].contains(status) ? .unavailable : .failed))
        }
    }

    @Test("The counter opens account details through the real UI event path")
    func badgeAction() throws {
        var opened = false
        let container = UIContainerView(rootView: EditorAICreditsBadge(model: EditorAICreditsModel(), compact: true, refresh: { _ in }, onOpen: { opened = true }))
        container.frame = Rect(x: 0, y: 0, width: 100, height: 40)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Counter"))
        #expect(opened)
    }

    @Test("Responses from a previous account never restore a cleared counter")
    func accountSwitchDuringRefresh() async throws {
        let gate = Gate()
        let model = EditorAICreditsModel()
        let client = EditorCloudAIClient(owner: owner) { path, _, _ in
            if path == "/ai/catalog" { await gate.wait(); return catalog }
            return wallet()
        }
        let task = Task { await model.refresh(client: client) }
        while gate.continuation == nil { await Task.yield() }
        model.reset(signedIn: false)
        gate.release()
        await task.value
        #expect(model.phase == .signedOut)
        #expect(model.balance == nil)
        #expect(model.catalog == nil)
        #expect(model.history.isEmpty)
    }

    @Test("Wrong owner, invalid scale and inconsistent balance are rejected")
    func invalidBalance() async {
        var malformed = wallet()
        malformed["accountID"] = "22222222-2222-4222-8222-222222222222"
        var wrongScale = wallet()
        wrongScale["scale"] = 1000
        for response in [malformed, wrongScale, wallet(available: 500_000_000), wallet(spent: -1)] {
            let client = EditorCloudAIClient(owner: owner) { _, _, _ in response }
            await #expect(throws: EditorAIError.self) { try await client.balance() }
        }
        let invalidOwner = EditorCloudAIClient(owner: "invalid") { _, _, _ in wallet() }
        await #expect(throws: EditorAIError.self) { try await invalidOwner.balance() }
    }

    @Test("Refresh requests coalesce and polling is throttled")
    func throttle() async {
        let model = EditorAICreditsModel()
        var calls = 0
        let client = EditorCloudAIClient(owner: owner) { path, _, _ in calls += 1; return path == "/ai/catalog" ? catalog : wallet() }
        let now = Date()
        await model.refresh(client: client, now: now)
        await model.refresh(client: client, now: now.addingTimeInterval(10))
        #expect(calls == 2)
        await model.refresh(client: client, now: now.addingTimeInterval(46))
        #expect(calls == 4)
    }

    @Test("A reservation that finishes during refresh triggers another balance fetch")
    func mutationDuringRefresh() async {
        let gate = Gate()
        let model = EditorAICreditsModel()
        var balanceCalls = 0
        let client = EditorCloudAIClient(owner: owner) { path, _, _ in
            if path == "/ai/catalog" { return catalog }
            balanceCalls += 1
            if balanceCalls == 1 {
                await gate.wait()
                return wallet(available: 500_000_000, spent: 0, reserved: 0)
            }
            return wallet(available: 425_000_000, spent: 0)
        }
        let task = Task { await model.refresh(client: client) }
        while gate.continuation == nil { await Task.yield() }
        await model.refresh(client: client, force: true)
        gate.release()
        await task.value
        for _ in 0..<100 {
            if model.counterText == "425 credits" { break }
            await Task.yield()
        }
        #expect(model.counterText == "425 credits")
        #expect(balanceCalls == 2)
    }

    @Test("Public quote and reservation requests preserve server contracts; path injection is rejected")
    func publicEndpoints() async throws {
        let quoteID = UUID().uuidString.lowercased()
        let reservationID = UUID().uuidString.lowercased()
        let input = EditorAIQuoteRequest(operationID: UUID().uuidString, requestDigest: String(repeating: "a", count: 64), capability: .mesh, maximum: .init(units: 1))
        let inputValue = try JSONDecoder().decode(EditorCloudValue.self, from: JSONEncoder().encode(input))
        let quote: EditorCloudValue = ["id": .string(quoteID), "accountID": .string(owner), "request": inputValue,
                                      "region": "russian", "country": "RU", "tariffVersion": "test", "maximumMicrocredits": 75_000_000, "expiresAt": 1_702_592_000]
        var reservation: EditorCloudValue = ["id": .string(reservationID), "accountID": .string(owner), "quote": quote,
                                            "cycleStart": 1_700_000_000, "state": "reserved", "expiresAt": 1_702_592_000, "chargedMicrocredits": 0]
        var calls: [(String, String, EditorCloudValue?)] = []
        let client = EditorCloudAIClient(owner: owner) { path, method, body in
            calls.append((path, method, body))
            return path == "/ai/quotes" ? quote : reservation
        }
        #expect(try await client.quote(input).maximumMicrocredits == 75_000_000)
        #expect(try await client.reserve(quoteID: quoteID).state == .reserved)
        #expect(try await client.reservation(id: reservationID).id == reservationID)
        reservation["state"] = "released"
        #expect(try await client.cancel(id: reservationID).state == .released)
        #expect(calls.map(\.0) == ["/ai/quotes", "/ai/reservations", "/ai/reservations/\(reservationID)", "/ai/reservations/\(reservationID)/cancel"])
        #expect(calls.map(\.1) == ["POST", "POST", "GET", "POST"])
        #expect(calls[0].2 == inputValue)
        #expect(calls[1].2 == ["quoteID": .string(quoteID)])
        await #expect(throws: EditorAIError.self) { try await client.cancel(id: "../internal/ai") }
        #expect(calls.count == 4)
    }

    @Test("History pages use the server cursor and reset with the account")
    func historyPagination() async {
        let model = EditorAICreditsModel()
        var paths: [String] = []
        let client = EditorCloudAIClient(owner: owner) { path, _, _ in
            paths.append(path)
            let after: Int64 = path.hasSuffix("=0") ? 0 : 50
            let count = after == 0 ? 50 : 1
            let entries = (1...count).map { offset -> EditorCloudValue in
                ["cursor": .integer(after + Int64(offset)), "cycleStart": 1_700_000_000,
                 "operationID": "operation", "kind": "settle", "microcredits": 1, "createdAt": 1_700_000_001]
            }
            return ["items": .array(entries), "nextCursor": .integer(after + Int64(count)), "scale": 1_000_000]
        }
        await model.loadHistory(client: client)
        #expect(model.hasMoreHistory)
        await model.loadHistory(client: client)
        #expect(!model.hasMoreHistory)
        #expect(model.history.count == 51)
        #expect(paths == ["/ai/usage?after=0", "/ai/usage?after=50"])
        model.reset(signedIn: true)
        #expect(model.history.isEmpty)
        await model.loadHistory(client: client)
        #expect(paths.last == "/ai/usage?after=0")
    }

    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
}
