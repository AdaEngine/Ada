@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

/// Optional disposable-local-service check. The session file is supplied by the test runner, never by the app.
@Suite("Cloud AI live API", .serialized)
@MainActor
struct EditorCloudAILiveTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AIWalletHTTPUI")))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_EDITOR_AI_TEST_SESSION"] != nil))
    func walletRoundTrip() async throws {
        struct Session: Decodable { var server: String; var accountID: String; var accessToken: String }
        let path = try #require(ProcessInfo.processInfo.environment["ADA_EDITOR_AI_TEST_SESSION"])
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let origin = try #require(URL(string: session.server))
        // Refuse to run a paid reservation test against a remote or production server.
        #expect(origin.scheme == "http")
        let host = try #require(origin.host)
        guard origin.scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) else {
            throw EditorAIError.invalidResponse
        }
        let client = EditorCloudAIClient(owner: session.accountID) { path, method, body in
            let url = try #require(URL(string: session.server + "/v1" + path))
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.map { try JSONEncoder().encode($0) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            guard (200..<300).contains(http.statusCode) else { throw EditorCloudAccount.CloudError.http(http.statusCode, "Local AI API test failed") }
            return try JSONDecoder().decode(EditorCloudValue.self, from: data)
        }
        let model = EditorAICreditsModel()
        model.reset(signedIn: true)
        await model.refresh(client: client)
        #expect(model.phase == .ready)
        #expect(model.counterText == "500 credits")
        #expect(model.catalog?.enabled == true)
        let container = UIContainerView(rootView: EditorAICreditsDetails(model: model, refresh: {}, loadHistory: {}))
        container.frame = Rect(x: 0, y: 0, width: 340, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Available"))
        let quote = try await client.quote(.init(operationID: UUID().uuidString, requestDigest: String(repeating: "a", count: 64), capability: .mesh, maximum: .init(units: 1)))
        #expect(quote.maximumMicrocredits == 75_000_000)
        let reserved = try await client.reserve(quoteID: quote.id)
        // Even on an assertion failure below, return the disposable wallet's unstarted reservation.
        do {
            #expect(try await client.reserve(quoteID: quote.id).id == reserved.id)
            #expect(try await client.reservation(id: reserved.id).state == .reserved)
            await model.refresh(client: client, force: true)
            #expect(model.counterText == "425 credits")
            #expect(model.balance?.reserved == 75_000_000)
            #expect(try await client.cancel(id: reserved.id).state == .released)
        } catch {
            _ = try? await client.cancel(id: reserved.id)
            throw error
        }
        await model.refresh(client: client, force: true)
        #expect(model.counterText == "500 credits")
        await model.loadHistory(client: client, restart: true)
        #expect(model.history.contains { $0.kind == "reserve" })
        #expect(model.history.contains { $0.kind == "release" })
    }
}
